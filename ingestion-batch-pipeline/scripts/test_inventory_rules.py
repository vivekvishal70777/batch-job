#!/usr/bin/env python3
"""Contract tests for inventory migration validation rules.

Mirrors src/main/resources/dwl/inventoryValidator.dwl so the rules can be
verified without a Mule runtime.
"""
from __future__ import annotations

import csv
import re
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SAMPLE_DIR = ROOT / "src" / "test" / "resources" / "sample"
ALLOWED_TYPES = {"Standard", "Backorder"}
MAX_QUANTITY = 999_999_999
TIMESTAMP_FORMATS = (
    "%Y-%m-%dT%H:%M:%S",
    "%Y-%m-%d %H:%M:%S",
    "%d-%m-%Y %H:%M:%S",
    "%m/%d/%Y %H:%M:%S",
    "%Y-%m-%d",
)


def is_blank(value: object) -> bool:
    return value is None or str(value).strip() == ""


def parse_quantity(value: object):
    if value is None:
        return None
    text = str(value).strip()
    if re.fullmatch(r"-?\d+", text):
        return int(text)
    if re.fullmatch(r"-?\d+\.\d+", text):
        return float(text)
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def is_non_negative_integer(value: object) -> bool:
    number = parse_quantity(value)
    if number is None:
        return False
    if isinstance(number, float) and not number.is_integer():
        return False
    as_int = int(number)
    return 0 <= as_int <= MAX_QUANTITY and float(number) == float(as_int)


def parse_timestamp(value: object):
    if is_blank(value):
        return None
    text = str(value).strip()
    for fmt in TIMESTAMP_FORMATS:
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    return None


def validation_errors(record: dict) -> list[str]:
    errors: list[str] = []
    if is_blank(record.get("SKU")):
        errors.append("SKU is mandatory")
    if is_blank(record.get("StoreId")):
        errors.append("StoreId is mandatory")
    if is_blank(record.get("Type")):
        errors.append("Type is mandatory")
    if is_blank(record.get("Quantity")):
        errors.append("Quantity is mandatory")
    timestamp = record.get("Timestamp") or record.get("SourceTimestamp")
    if is_blank(timestamp):
        errors.append("Timestamp is mandatory")
    record_type = record.get("Type")
    if not is_blank(record_type) and record_type not in ALLOWED_TYPES:
        errors.append("Type must be one of: Standard, Backorder")
    if not is_blank(record.get("Quantity")) and not is_non_negative_integer(record.get("Quantity")):
        errors.append("Quantity must be a whole number between 0 and 999999999")
    if not is_blank(timestamp) and parse_timestamp(timestamp) is None:
        errors.append("Timestamp is not a recognized date/time")
    return errors


def is_valid(record: dict) -> bool:
    return not validation_errors(record)


def read_csv(path: Path) -> list[dict]:
    with path.open(newline="", encoding="utf-8") as handle:
        return list(csv.DictReader(handle))


def assert_true(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def test_unit_rules() -> None:
    valid = {
        "SKU": "SKU-1",
        "StoreId": "STORE-01",
        "Type": "Standard",
        "Quantity": "10",
        "Timestamp": "2026-08-01 08:00:00",
    }
    assert_true(is_valid(valid), "expected a complete Standard row to pass")
    assert_true(
        is_valid({**valid, "Type": "Backorder", "Quantity": "0", "Timestamp": "2026-08-01T08:00:00"}),
        "expected Backorder with zero quantity to pass",
    )
    assert_true(not is_valid({**valid, "SKU": ""}), "empty SKU must fail")
    assert_true(not is_valid({**valid, "StoreId": ""}), "empty StoreId must fail")
    assert_true(not is_valid({**valid, "Type": "Express"}), "unknown Type must fail")
    assert_true(not is_valid({**valid, "Quantity": "-1"}), "negative Quantity must fail")
    assert_true(not is_valid({**valid, "Quantity": "1.5"}), "fractional Quantity must fail")
    assert_true(not is_valid({**valid, "Timestamp": "not-a-date"}), "invalid Timestamp must fail")
    assert_true(is_valid({**valid, "Timestamp": "01-08-2026 08:15:00"}), "dd-MM-yyyy timestamp must pass")


def test_sample_files() -> None:
    valid_rows = read_csv(SAMPLE_DIR / "inventory-valid.csv")
    invalid_rows = read_csv(SAMPLE_DIR / "inventory-invalid.csv")
    assert_true(len(valid_rows) == 4, f"expected 4 valid fixture rows, got {len(valid_rows)}")
    assert_true(len(invalid_rows) == 6, f"expected 6 invalid fixture rows, got {len(invalid_rows)}")
    for index, row in enumerate(valid_rows, start=2):
        assert_true(is_valid(row), f"valid fixture line {index} failed: {validation_errors(row)}")
    for index, row in enumerate(invalid_rows, start=2):
        assert_true(not is_valid(row), f"invalid fixture line {index} unexpectedly passed")


def main() -> int:
    tests = [test_unit_rules, test_sample_files]
    failed = 0
    for test in tests:
        try:
            test()
            print(f"PASS  {test.__name__}")
        except Exception as exc:  # noqa: BLE001 - report and continue
            failed += 1
            print(f"FAIL  {test.__name__}: {exc}")
    if failed:
        print(f"{failed} test(s) failed")
        return 1
    print(f"{len(tests)} test(s) passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
