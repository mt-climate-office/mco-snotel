"""Freshness check: alert when latest/manifest.json is stale or missing.

Reads s3://$BUCKET/$KEY and publishes to $TOPIC_ARN when the manifest is
missing or unreadable, has no valid "date", or its date is more than
$MAX_AGE_DAYS days before today in America/Denver. Kept identical in
mco-snodas and mco-snotel (terraform/lambda/freshness.py).
"""

import datetime
import json
import os

import boto3

s3 = boto3.client("s3")
sns = boto3.client("sns")


def mountain_today():
    try:
        from zoneinfo import ZoneInfo

        tz = ZoneInfo("America/Denver")
    except Exception:  # no tz database in the runtime: use MST
        tz = datetime.timezone(datetime.timedelta(hours=-7))
    return datetime.datetime.now(tz).date()


def handler(event, context):
    project = os.environ["PROJECT"]
    bucket = os.environ["BUCKET"]
    key = os.environ["KEY"]
    max_age = int(os.environ["MAX_AGE_DAYS"])
    url = f"s3://{bucket}/{key}"

    today = mountain_today()
    oldest_ok = today - datetime.timedelta(days=max_age)

    problem = None
    date = None
    try:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        date = datetime.date.fromisoformat(json.loads(body)["date"])
    except s3.exceptions.NoSuchKey:
        problem = f"{url} is missing."
    except Exception as e:  # unreadable, not JSON, no or bad "date"
        problem = f"Could not read a date from {url}: {type(e).__name__}: {e}"
    else:
        if date < oldest_ok:
            problem = (
                f"{url} is stale: date {date}, today {today} (America/Denver); "
                f"alerts when older than {oldest_ok}."
            )

    result = {"project": project, "manifest": url, "date": str(date), "today": str(today)}
    if problem is None:
        print(json.dumps({"ok": True, **result}))
        return {"ok": True, **result}

    print(json.dumps({"ok": False, "problem": problem, **result}))
    sns.publish(
        TopicArn=os.environ["TOPIC_ARN"],
        Subject=f"{project}: latest/manifest.json is stale or missing"[:100],
        Message=(
            f"{problem}\n\n"
            f"The daily run publishes latest/ at about 10:00 America/Denver. Check "
            f"the ECS task and its logs in CloudWatch ({os.environ.get('LOG_GROUP', '')})."
        ),
    )
    return {"ok": False, "problem": problem, **result}
