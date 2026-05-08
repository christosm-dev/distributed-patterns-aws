variable "name" {
  description = "Table name"
  type        = string
}

variable "hash_key" {
  description = "Partition key attribute name"
  type        = string
}

variable "hash_key_type" {
  description = "Partition key type: S, N, or B"
  type        = string
  default     = "S"
}

variable "range_key" {
  description = "Sort key attribute name (optional)"
  type        = string
  default     = null
}

variable "range_key_type" {
  description = "Sort key type: S, N, or B"
  type        = string
  default     = "S"
}

variable "ttl_attribute" {
  description = "TTL attribute name. Leave empty to disable TTL."
  type        = string
  default     = ""
}

variable "global_secondary_indexes" {
  description = "List of GSI definitions"
  type = list(object({
    name            = string
    hash_key        = string
    hash_key_type   = string
    range_key       = optional(string)
    range_key_type  = optional(string)
    projection_type = string
  }))
  default = []
}

variable "tags" {
  type    = map(string)
  default = {}
}

locals {
  # Collect all attribute definitions, deduplicating by name
  all_attributes = distinct(concat(
    [{ name = var.hash_key, type = var.hash_key_type }],
    var.range_key != null ? [{ name = var.range_key, type = var.range_key_type }] : [],
    [for gsi in var.global_secondary_indexes : { name = gsi.hash_key, type = gsi.hash_key_type }],
    flatten([for gsi in var.global_secondary_indexes :
      gsi.range_key != null ? [{ name = gsi.range_key, type = coalesce(gsi.range_key_type, "S") }] : []
    ])
  ))
}

resource "aws_dynamodb_table" "this" {
  name         = var.name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = var.hash_key
  range_key    = var.range_key

  dynamic "attribute" {
    for_each = local.all_attributes
    content {
      name = attribute.value.name
      type = attribute.value.type
    }
  }

  dynamic "ttl" {
    for_each = var.ttl_attribute != "" ? [1] : []
    content {
      attribute_name = var.ttl_attribute
      enabled        = true
    }
  }

  dynamic "global_secondary_index" {
    for_each = var.global_secondary_indexes
    content {
      name            = global_secondary_index.value.name
      hash_key        = global_secondary_index.value.hash_key
      range_key       = lookup(global_secondary_index.value, "range_key", null)
      projection_type = global_secondary_index.value.projection_type
    }
  }

  tags = var.tags
}

output "table_name" {
  value = aws_dynamodb_table.this.name
}

output "table_arn" {
  value = aws_dynamodb_table.this.arn
}
