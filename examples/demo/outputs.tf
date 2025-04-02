output "secrets" {
  description = "List of secrets"
  value       = data.ibm_sm_secrets.secrets.secrets
}
