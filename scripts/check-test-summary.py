"""Reject empty, failed or incomplete simulator runs before recording success."""
import json
import sys


def validate(summary):
    fields = ["totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"]
    if any(type(summary.get(key)) is not int for key in fields):
        raise ValueError("Missing or invalid test counts in xcresult summary")
    if (summary.get("result") != "Passed" or summary["totalTestCount"] <= 0
            or summary["passedTests"] != summary["totalTestCount"]
            or any(summary[key] != 0 for key in ["failedTests", "skippedTests", "expectedFailures"])):
        raise ValueError("Simulator selection must execute tests with no failures or skips")


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as source:
        summary = json.load(source)
    validate(summary)
    print(f"Verified {summary['passedTests']} passing simulator tests; no failures or skips.")
