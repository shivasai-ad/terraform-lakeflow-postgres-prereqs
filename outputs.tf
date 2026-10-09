output "parameter_group_name" {
  description = "Attach this to the database, then reboot (scripts/reboot.sh)."
  value       = module.cdc_source.parameter_group_name
}

output "max_slot_wal_keep_size_mb" {
  description = "WAL retention cap applied (MB)."
  value       = module.cdc_source.max_slot_wal_keep_size_mb
}

output "secret_arn" {
  description = "Secret holding the credentials. Null until Phase 2."
  value       = module.cdc_source.secret_arn
}

output "expected_state" {
  description = "What scripts/verify.sh should find after Phase 2."
  value       = module.cdc_source.expected_state
}

output "next_step" {
  value = module.cdc_source.next_step
}
