import os

import boto3
from boto3.dynamodb.conditions import Attr

SOURCE_NAME = os.environ["SOURCE_NAME"]
TABLE_NAME  = os.environ["TABLE_NAME"]

_dynamodb = boto3.resource("dynamodb", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))


def handler(event, context):
    query  = event.get("query", "").lower()
    table  = _dynamodb.Table(TABLE_NAME)

    response = table.scan(FilterExpression=Attr("keywords").contains(query))
    results  = response.get("Items", [])

    return {
        "source":  SOURCE_NAME,
        "success": True,
        "results": results,
        "count":   len(results),
    }
