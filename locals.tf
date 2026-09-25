locals {
  # HTTPS is toggled by the presence of a certificate, not a separate boolean (constitution §1.1).
  https_enabled = var.web.certificate_arn != null

  # The data tier is all-or-nothing and toggled by the presence of the database object (FR-10).
  database_enabled = var.database != null

  # Every caller-supplied subnet, flattened so check.subnets_in_vpc can verify them in one lookup.
  check_subnet_ids = concat(
    values(var.vpc.public_subnet_ids),
    values(var.vpc.private_subnet_ids),
    values(var.vpc.database_subnet_ids),
  )

  # AWS caps target group name_prefix at 6 characters; a prefix (not a name) lets the group be replaced before destroy.
  target_group_name_prefix = substr(var.app.name, 0, 6)

  # skip_final_snapshot = false requires a snapshot name that plan does not enforce, so derive it to keep destroy working.
  database_final_snapshot_identifier = local.database_enabled ? "${var.database.name}-final" : null
}
