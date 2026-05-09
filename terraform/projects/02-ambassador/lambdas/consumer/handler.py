import json


def handler(event, context):
    for record in event["Records"]:
        body = json.loads(record["body"])
        print(json.dumps({
            "message_id":  body.get("message_id"),
            "body":        body.get("body"),
            "produced_at": body.get("produced_at"),
            "status":      "processed",
        }))
    return {"processed": len(event["Records"])}
