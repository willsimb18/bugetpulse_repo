#!/usr/bin/env python3
"""
Migrate the on-prem SQL Server `Finance` database into Supabase.

    pip install pyodbc "psycopg[binary]"

    export MSSQL_CONN='DRIVER={ODBC Driver 18 for SQL Server};SERVER=...;DATABASE=Finance;UID=...;PWD=...;TrustServerCertificate=yes'
    export SUPABASE_DB_URL='postgresql://postgres:...@db.<ref>.supabase.co:5432/postgres'
    export HOUSEHOLD_ID='<uuid from 06_bootstrap.sql>'

    python migrate.py --dry-run     # read + transform, print counts, write nothing
    python migrate.py               # load

Credentials come from the environment. Nothing is hardcoded, and the script
never prints a connection string.

THE IMPORTANT PART
------------------
`Budget.AccountId` is polymorphic: it points into Bills, Expenses,
SavingAccounts, or Debts depending on which of IsBill/IsExpenses/isSaving/
isDebt is set. Those four tables have independent IDENTITY sequences, so
BillId 3 and ExpenseID 3 both exist. Resolution therefore always keys on
(kind, legacy_id) — never on legacy_id alone. Getting this wrong silently
attaches history to the wrong account, which is the single biggest risk in
this migration.
"""

from __future__ import annotations

import argparse
import os
import sys
from collections import defaultdict
from decimal import Decimal

FREQ = {
    "Bi-Weekly": "biweekly", "BiWeekly": "biweekly", "Weekly": "weekly",
    "Monthly": "monthly", "Semi-Monthly": "semimonthly", "Quarterly": "quarterly",
    "Semi-Annually": "semiannual", "Annually": "annual", "Annual": "annual",
    "One Time": "one_time", "N/A": "per_paycheck", "n/a": "per_paycheck",
}

PAY_TYPE = {
    "FullTime": "regular", "Full Time": "regular", "Regular": "regular",
    "Overtime": "overtime", "PTO": "pto", "Holiday": "holiday",
    "Bonus": "bonus", "Commission": "commission",
}

INCOME_TYPE = {
    "Wages": "regular", "Salary": "regular", "Bonus": "bonus",
    "Deposits": "deposit", "Deposit": "deposit", "Tax Refund": "tax_refund",
    "Line Of Credit": "line_of_credit", "LineOfCredit": "line_of_credit",
}

DEBT_TYPE = {
    "Credit Cards": "credit_card", "Credit Card": "credit_card",
    "Auto Loans": "auto_loan", "Auto Loan": "auto_loan",
    "Mortgage": "mortgage", "Personal Loans": "personal_loan",
    "Student Loans": "student_loan",
}


def kind_of(row) -> str:
    """isBill/isDebt/isSaving/isExpenses -> one enum. First true wins."""
    if row.get("IsBill"):
        return "bill"
    if row.get("isDebt"):
        return "debt"
    if row.get("isSaving"):
        return "saving"
    return "expense"


def freq(v, default="monthly") -> str:
    return FREQ.get((v or "").strip(), default)


def clean(v):
    return (v or "").strip() or None


# ---------------------------------------------------------------- extract
def read_source(cur) -> dict:
    """Pull every table we need out of SQL Server as lists of dicts."""

    def q(sql):
        cur.execute(sql)
        cols = [c[0] for c in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]

    return {
        "categories": q("SELECT TypeId, TypeName, ParentTypeId, TypeDescription FROM CategoryType"),
        "users": q("SELECT UserId, UserName, FirstName, LastName FROM Users"),
        "paytypes": q("SELECT PayTypeId, PayType FROM PayType"),
        "wages": q("""SELECT WageId, PayTypeId, UserId, Salary, WageAmount, Taxes,
                             Healthcare, [401K] AS Retirement, isCurrent, NumOfDependents
                      FROM Wages"""),
        "freqs": q("SELECT FrequencyId, Frequence FROM AccountFrequencies"),
        "bills": q("""SELECT BillId, CategoryTypeId, BillName, isActive, Amount,
                             DueDate, FrequencyId FROM Bills"""),
        "expenses": q("SELECT ExpenseID, CategoryTypeId, ExpenseName, isNew, Amount FROM Expenses"),
        "savings": q("SELECT SavingId, AccountName, isActive, CategoryTypeId FROM SavingAccounts"),
        "debts": q("""SELECT DebtId, DebtTypeId, CategoryTypeId, Account, isActive,
                             CreditAmount, MonthlyPaymentAmount, DayDueOn, APR FROM Debts"""),
        "debttypes": q("SELECT DebtTypeId, TypeName FROM DebtType"),
        "incometypes": q("SELECT IncomeTypeId, IncomeTypeName FROM IncomeType"),
        "budgetincome": q("""SELECT BudgetIncomeID, PayDate, IncomeTypeID, Amount,
                                    IncomeType2ID, OtherAmount, IncomeType3ID, OtherAmount2
                             FROM BudgetIncome"""),
        "budget": q("""SELECT BudgetId, PayDate, BudgetIncomeID, AccountId, CategoryTypeId,
                              Amount, IsBill, IsExpenses, isSaving, isDebt, DueDate,
                              FundsHeld, FundsHeldAmount, FundsHeldUpToDate, FundsOnHoldAmt
                       FROM Budget ORDER BY PayDate, BudgetId"""),
        "banks": q("SELECT BankId, BankName FROM Banks"),
        "statements": q("""SELECT StatementId, StatementDate, BankId, TransactionDate,
                                  CategoryTypeId, AccountID, AccountType, TransDescription, Amount
                           FROM EStatements"""),
        "keywords": q("SELECT KeywordID, Keyword, Category, SubCategory FROM KeywordsCategoryMapping"),
    }


# ---------------------------------------------------------------- load
def load(pg, src: dict, household: str, dry: bool) -> dict:
    cur = pg.cursor()
    stats: dict[str, int] = defaultdict(int)

    def ex(sql, args=()):
        cur.execute(sql, args)

    # ---- categories: parents first, then children, so parent_id resolves
    cat_id: dict[int, int] = {}          # legacy TypeId -> new id
    parents = [c for c in src["categories"] if c["ParentTypeId"] is None]
    children = [c for c in src["categories"] if c["ParentTypeId"] is not None]

    for c in parents + children:
        parent = cat_id.get(c["ParentTypeId"]) if c["ParentTypeId"] else None
        ex(
            """insert into category (household_id, name, parent_id, description,
                                     legacy_type_id, is_income)
               values (%s,%s,%s,%s,%s,%s)
               on conflict (household_id, name, parent_id) do update
                 set legacy_type_id = excluded.legacy_type_id
               returning id""",
            (household, c["TypeName"].strip(), parent, clean(c["TypeDescription"]),
             c["TypeId"], (c["TypeName"] or "").strip() == "Income"),
        )
        cat_id[c["TypeId"]] = cur.fetchone()[0]
        stats["category"] += 1

    # ---- earners
    earner_id: dict[int, int] = {}
    for u in src["users"]:
        name = clean(u["FirstName"]) or clean(u["UserName"]) or f"User {u['UserId']}"
        ex(
            """insert into earner (household_id, display_name, pay_frequency)
               values (%s,%s,'biweekly')
               on conflict (household_id, display_name) do update
                 set is_active = true
               returning id""",
            (household, name),
        )
        earner_id[u["UserId"]] = cur.fetchone()[0]
        stats["earner"] += 1

    # ---- wage rates. Wages.isCurrent keeps one row per person, so there is
    # no history to import — this seeds a single starting rate per earner and
    # every future raise becomes a new effective-dated row.
    paytype = {p["PayTypeId"]: p["PayType"] for p in src["paytypes"]}
    earliest = min((b["PayDate"] for b in src["budget"]), default=None)
    for w in src["wages"]:
        if not w["isCurrent"]:
            continue
        if PAY_TYPE.get((paytype.get(w["PayTypeId"]) or "").strip()) != "regular":
            continue          # OT/PTO/Holiday rows are not a base rate
        eid = earner_id.get(w["UserId"])
        if not eid or not earliest:
            continue
        ex(
            """insert into wage_rate (household_id, earner_id, effective_from,
                   hourly_rate, annual_salary, standard_hours,
                   taxes_est, healthcare_est, retirement_est, note)
               values (%s,%s,%s,%s,%s,80,%s,%s,%s,'Imported from Finance')
               on conflict (earner_id, effective_from) do nothing""",
            (household, eid, earliest, w["WageAmount"] or None,
             w["Salary"] or None, w["Taxes"] or 0, w["Healthcare"] or 0,
             w["Retirement"] or 0),
        )
        stats["wage_rate"] += 1

    # ---- accounts: the four catalogs collapse into one table.
    # acct[(kind, legacy_id)] -> new account id
    acct: dict[tuple[str, int], int] = {}
    freq_name = {f["FrequencyId"]: f["Frequence"] for f in src["freqs"]}

    def schedule_for(f, due, day=None):
        """(due_day, anchor_date, is_always_due) for one source row.

        account_schedule_present requires one of the three for any frequency
        other than per_paycheck/one_time. Finance allows a bill with no
        DueDate at all, and Semi-Monthly was never mapped here, so both used
        to produce a row the constraint rejects. Fall back instead of
        aborting the whole load, and count each fallback so the dry run
        shows how much of the catalog was guessed at.
        """
        if f in ("per_paycheck", "one_time"):
            return None, None, False
        if f in ("weekly", "biweekly"):
            if due:
                return None, due, False
            if earliest:
                # No date on the source row. Anchor to the first pay date so
                # the cadence is still real rather than inventing one.
                stats["schedule_anchored_to_first_paydate"] += 1
                return None, earliest, False
        else:
            d = day or (due.day if due else None)
            if d:
                return d, None, False
        # Nothing to schedule from: treat it as due in every period, which is
        # what CTE_AlwaysDueList did for these by hand.
        stats["schedule_defaulted_always_due"] += 1
        return None, None, True

    def add_account(kind, legacy_id, name, cat_legacy, amount, active,
                    frequency, due_day=None, anchor=None, always=False):
        name = (name or "").strip()
        if not name:
            return
        ex(
            """insert into account (household_id, name, kind, category_id, frequency,
                   default_amount, due_day, anchor_date, is_active, amount_mode,
                   is_always_due)
               values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
               on conflict (household_id, name, kind) do update
                 set default_amount = excluded.default_amount
               returning id""",
            (household, name, kind, cat_id.get(cat_legacy), frequency,
             amount or 0, due_day, anchor, bool(active),
             # Your Excel rule was carry-forward for everything; debts and
             # savings are steadier, so they start fixed. Change per bill later.
             "carry_forward" if kind in ("bill", "expense") else "fixed",
             bool(always)),
        )
        acct[(kind, legacy_id)] = cur.fetchone()[0]
        stats[f"account_{kind}"] += 1

    for b in src["bills"]:
        f = freq(freq_name.get(b["FrequencyId"]), "monthly")
        due_day, anchor, always = schedule_for(f, b["DueDate"])
        add_account(
            "bill", b["BillId"], b["BillName"], b["CategoryTypeId"], b["Amount"],
            b["isActive"], f, due_day=due_day, anchor=anchor, always=always,
        )

    for e in src["expenses"]:
        # isNew flags "in the current paycheck". Any expense that has ever been
        # used stays in the catalog; per-period inclusion is now a budget_line.
        add_account("expense", e["ExpenseID"], e["ExpenseName"], e["CategoryTypeId"],
                    e["Amount"], True, "per_paycheck")

    for s in src["savings"]:
        add_account("saving", s["SavingId"], s["AccountName"], s["CategoryTypeId"],
                    0, s["isActive"], "per_paycheck")

    dtype = {d["DebtTypeId"]: d["TypeName"] for d in src["debttypes"]}
    for d in src["debts"]:
        due_day, anchor, always = schedule_for("monthly", None, d["DayDueOn"] or None)
        add_account("debt", d["DebtId"], d["Account"], d["CategoryTypeId"],
                    d["MonthlyPaymentAmount"], d["isActive"], "monthly",
                    due_day=due_day, anchor=anchor, always=always)
        aid = acct.get(("debt", d["DebtId"]))
        if not aid:
            continue
        ex(
            """insert into debt_detail (account_id, household_id, debt_type,
                   credit_limit, apr, minimum_payment)
               values (%s,%s,%s,%s,%s,%s)
               on conflict (account_id) do update set apr = excluded.apr""",
            (aid, household, DEBT_TYPE.get((dtype.get(d["DebtTypeId"]) or "").strip(), "other"),
             d["CreditAmount"] or None,
             # APR is stored as whole percent in decimal(5,2) and divided by
             # 100 in vw_Debts. Normalise to a fraction on the way in.
             (Decimal(d["APR"]) / 100) if d["APR"] is not None else None,
             d["MonthlyPaymentAmount"] or None),
        )
        stats["debt_detail"] += 1

    # ---- budget periods from the distinct pay dates in Budget
    paydates = sorted({b["PayDate"] for b in src["budget"] if b["PayDate"]})
    opening = {bi["PayDate"]: bi for bi in src["budgetincome"]}
    period_id: dict[object, int] = {}

    for i, pd in enumerate(paydates):
        end = (paydates[i + 1] - pd).days - 1 if i + 1 < len(paydates) else 13
        end = max(end, 0)
        ex(
            """insert into budget_period (household_id, period_start, period_end,
                   pay_date, frequency, label, is_closed, opening_balance)
               values (%s,%s,%s + %s, %s,'biweekly',%s,true,0)
               on conflict (household_id, period_start, frequency) do nothing
               returning id""",
            (household, pd, pd, end, pd,
             pd.strftime("%b %d, %Y") if hasattr(pd, "strftime") else str(pd)),
        )
        row = cur.fetchone()
        if row is None:
            ex("""select id from budget_period
                  where household_id=%s and period_start=%s and frequency='biweekly'""",
               (household, pd))
            row = cur.fetchone()
        period_id[pd] = row[0]
        stats["budget_period"] += 1

    # ---- income: unpivot BudgetIncome's three repeating pairs
    itype = {i["IncomeTypeId"]: i["IncomeTypeName"] for i in src["incometypes"]}
    for bi in src["budgetincome"]:
        pid = period_id.get(bi["PayDate"])
        for tid, amt in (
            (bi["IncomeTypeID"], bi["Amount"]),
            (bi["IncomeType2ID"], bi["OtherAmount"]),
            (bi["IncomeType3ID"], bi["OtherAmount2"]),
        ):
            if not tid or not amt:
                continue
            ex(
                """insert into income (household_id, earner_id, budget_period_id,
                       received_on, kind, gross_override, notes)
                   values (%s,null,%s,%s,%s,%s,'Imported from BudgetIncome')""",
                (household, pid, bi["PayDate"],
                 INCOME_TYPE.get((itype.get(tid) or "").strip(), "other"), amt),
            )
            stats["income"] += 1

    # ---- budget lines. Every historical row is settled, so amount_due ==
    # amount_paid and status is 'paid'. amount_overridden is TRUE so the
    # nightly refresh can never reprice imported history.
    unresolved = 0
    for b in src["budget"]:
        kind = kind_of(b)
        aid = acct.get((kind, b["AccountId"]))          # <-- (kind, id), never id alone
        if aid is None:
            unresolved += 1
            continue
        pid = period_id.get(b["PayDate"])
        if pid is None:
            continue
        ex(
            """insert into budget_line (household_id, budget_period_id, account_id, name,
                   category_id, kind, due_date, amount_due, amount_paid, amount_overridden,
                   status, paid_on, funds_held, funds_held_amount, funds_held_until)
               select %s,%s,%s,a.name,%s,%s,%s,%s,%s,true,'paid',%s,%s,%s,%s
               from account a where a.id = %s
               on conflict (budget_period_id, account_id, due_date)
                 where account_id is not null do nothing""",
            (household, pid, aid, cat_id.get(b["CategoryTypeId"]), kind,
             b["DueDate"] or b["PayDate"], b["Amount"] or 0, b["Amount"] or 0,
             b["DueDate"] or b["PayDate"],
             bool(b["FundsHeld"]), b["FundsOnHoldAmt"] or 0,
             b["FundsHeldUpToDate"], aid),
        )
        stats["budget_line"] += 1

    stats["budget_line_unresolved"] = unresolved

    # ---- banks + statements. account_ref keeps last 4 only.
    bank_id: dict[int, int] = {}
    for bk in src["banks"]:
        ex("""insert into bank (household_id, name) values (%s,%s)
              on conflict (household_id, name) do update set name = excluded.name
              returning id""",
           (household, (bk["BankName"] or f"Bank {bk['BankId']}").strip()))
        bank_id[bk["BankId"]] = cur.fetchone()[0]

    for s in src["statements"]:
        ex(
            """insert into statement_txn (household_id, bank_id, statement_date, txn_date,
                   description, amount, category_id, account_ref, account_type, external_id)
               values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
               on conflict (household_id, external_id) do nothing""",
            (household, bank_id.get(s["BankId"]), s["StatementDate"],
             s["TransactionDate"] or s["StatementDate"], clean(s["TransDescription"]),
             s["Amount"] or 0, cat_id.get(s["CategoryTypeId"]),
             str(s["AccountID"])[-4:] if s["AccountID"] is not None else None,
             clean(s["AccountType"]), str(s["StatementId"])),
        )
        stats["statement_txn"] += 1

    # ---- keyword rules
    by_name = {}
    ex("select id, name, parent_id from category where household_id = %s", (household,))
    for cid, nm, par in cur.fetchall():
        by_name.setdefault(nm.strip().lower(), cid)
    for k in src["keywords"]:
        target = by_name.get((k["SubCategory"] or "").strip().lower()) \
              or by_name.get((k["Category"] or "").strip().lower())
        if not target:
            continue
        ex("""insert into category_keyword (household_id, keyword, category_id)
              values (%s,%s,%s) on conflict (household_id, keyword) do nothing""",
           (household, k["Keyword"].strip(), target))
        stats["category_keyword"] += 1

    if dry:
        pg.rollback()
    else:
        pg.commit()
    return dict(stats)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true",
                    help="transform and roll back; nothing is written")
    args = ap.parse_args()

    for var in ("MSSQL_CONN", "SUPABASE_DB_URL", "HOUSEHOLD_ID"):
        if not os.environ.get(var):
            print(f"Missing environment variable {var}", file=sys.stderr)
            return 2

    import psycopg
    import pyodbc

    with pyodbc.connect(os.environ["MSSQL_CONN"]) as ms:
        src = read_source(ms.cursor())
    print("read from SQL Server: " +
          ", ".join(f"{k}={len(v)}" for k, v in sorted(src.items())))

    with psycopg.connect(os.environ["SUPABASE_DB_URL"]) as pg:
        # Audit triggers would double the write volume on a bulk load.
        pg.execute("alter table budget_line disable trigger t_budget_line_audit")
        pg.execute("alter table account     disable trigger t_account_audit")
        pg.execute("alter table income      disable trigger t_income_audit")
        try:
            stats = load(pg, src, os.environ["HOUSEHOLD_ID"], args.dry_run)
        finally:
            # A failed load leaves the transaction aborted, so every statement
            # below would fail too and bury the error that actually mattered.
            pg.rollback()
            pg.execute("alter table budget_line enable trigger t_budget_line_audit")
            pg.execute("alter table account     enable trigger t_account_audit")
            pg.execute("alter table income      enable trigger t_income_audit")
            pg.commit()

    print("\nloaded:" if not args.dry_run else "\nwould load (rolled back):")
    for k, v in sorted(stats.items()):
        print(f"  {k:28} {v}")
    if stats.get("budget_line_unresolved"):
        print(f"\n  {stats['budget_line_unresolved']} Budget rows had an AccountId with no "
              f"matching catalog row and were skipped — check for deleted Bills/Expenses.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
