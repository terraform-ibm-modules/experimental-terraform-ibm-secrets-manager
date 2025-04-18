########################################################################################################################
# Resource Group
########################################################################################################################
locals {
  # tflint-ignore: terraform_unused_declarations
  validate_resource_group = (var.existing_secrets_manager_crn == null && var.resource_group_name == null) ? tobool("Resource group name can not be null if existing secrets manager CRN is not set.") : true
  # tflint-ignore: terraform_unused_declarations
  validate_event_notifications = (var.existing_event_notifications_instance_crn == null && var.enable_event_notifications) ? tobool("To enable event notifications, an existing event notifications CRN must be set.") : true
  prefix                       = var.prefix != null ? (var.prefix != "" ? var.prefix : null) : null
}

module "resource_group" {
  count                        = var.existing_secrets_manager_crn == null ? 1 : 0
  source                       = "terraform-ibm-modules/resource-group/ibm"
  version                      = "1.1.6"
  resource_group_name          = var.use_existing_resource_group == false ? try("${local.prefix}-${var.resource_group_name}", var.resource_group_name) : null
  existing_resource_group_name = var.use_existing_resource_group == true ? var.resource_group_name : null
}

#######################################################################################################################
# KMS Key
#######################################################################################################################
locals {
  kms_key_crn       = var.existing_secrets_manager_crn == null ? (var.existing_secrets_manager_kms_key_crn != null ? var.existing_secrets_manager_kms_key_crn : module.kms[0].keys[format("%s.%s", local.kms_key_ring_name, local.kms_key_name)].crn) : var.existing_secrets_manager_kms_key_crn
  kms_key_ring_name = try("${local.prefix}-${var.kms_key_ring_name}", var.kms_key_ring_name)
  kms_key_name      = try("${local.prefix}-${var.kms_key_name}", var.kms_key_name)

  parsed_existing_kms_instance_crn = var.existing_kms_instance_crn != null ? split(":", var.existing_kms_instance_crn) : []
  kms_region                       = length(local.parsed_existing_kms_instance_crn) > 0 ? local.parsed_existing_kms_instance_crn[5] : null

  parsed_service_name = var.existing_kms_instance_crn != null ? module.kms_instance_crn_parser[0].service_name : module.kms_key_crn_parser[0].service_name
  is_hpcs_key         = local.parsed_service_name == "hs-crypto" ? true : false

  create_cross_account_auth_policy      = var.existing_secrets_manager_crn == null && !var.skip_kms_iam_authorization_policy && var.ibmcloud_kms_api_key != null
  create_cross_account_hpcs_auth_policy = local.create_cross_account_auth_policy == true && local.is_hpcs_key ? 1 : 0

  kms_service_name  = var.existing_secrets_manager_kms_key_crn != null ? module.kms_key_crn_parser[0].service_name : module.kms_instance_crn_parser[0].service_name
  kms_key_id        = var.existing_secrets_manager_kms_key_crn != null ? module.kms_key_crn_parser[0].resource : module.kms_instance_crn_parser[0].resource
  kms_instance_guid = var.existing_secrets_manager_kms_key_crn != null ? module.kms_key_crn_parser[0].service_instance : module.kms_instance_crn_parser[0].service_instance
  kms_account_id    = var.existing_secrets_manager_kms_key_crn != null ? module.kms_key_crn_parser[0].account_id : module.kms_instance_crn_parser[0].account_id

}
# Lookup account ID
data "ibm_iam_account_settings" "iam_account_settings" {
  count = local.create_cross_account_auth_policy ? 1 : 0
}

########################################################################################################################
# Parse KMS info from given CRNs
########################################################################################################################

module "kms_instance_crn_parser" {
  count   = var.existing_kms_instance_crn != null ? 1 : 0
  source  = "terraform-ibm-modules/common-utilities/ibm//modules/crn-parser"
  version = "1.1.0"
  crn     = var.existing_kms_instance_crn
}

module "kms_key_crn_parser" {
  count   = var.existing_secrets_manager_kms_key_crn != null ? 1 : 0
  source  = "terraform-ibm-modules/common-utilities/ibm//modules/crn-parser"
  version = "1.1.0"
  crn     = var.existing_secrets_manager_kms_key_crn
}

# Create auth policy (scoped to exact KMS key)
resource "ibm_iam_authorization_policy" "kms_policy" {
  count                    = local.create_cross_account_auth_policy ? 1 : 0
  provider                 = ibm.kms
  source_service_account   = data.ibm_iam_account_settings.iam_account_settings[0].account_id
  source_service_name      = "secrets-manager"
  source_resource_group_id = module.resource_group[0].resource_group_id
  roles                    = ["Reader"]
  description              = "Allow all Secrets Manager instances in the resource group ${module.resource_group[0].resource_group_id} in the account ${data.ibm_iam_account_settings.iam_account_settings[0].account_id} to read the ${local.kms_service_name} key ${local.kms_key_id} from the instance GUID ${local.kms_instance_guid}"
  resource_attributes {
    name     = "serviceName"
    operator = "stringEquals"
    value    = local.kms_service_name
  }
  resource_attributes {
    name     = "accountId"
    operator = "stringEquals"
    value    = local.kms_account_id
  }
  resource_attributes {
    name     = "serviceInstance"
    operator = "stringEquals"
    value    = local.kms_instance_guid
  }
  resource_attributes {
    name     = "resourceType"
    operator = "stringEquals"
    value    = "key"
  }
  resource_attributes {
    name     = "resource"
    operator = "stringEquals"
    value    = local.kms_key_id
  }
  # Scope of policy now includes the key, so ensure to create new policy before
  # destroying old one to prevent any disruption to every day services.
  lifecycle {
    create_before_destroy = true
  }

}
# workaround for https://github.com/IBM-Cloud/terraform-provider-ibm/issues/4478
resource "time_sleep" "wait_for_authorization_policy" {
  count           = local.create_cross_account_auth_policy ? 1 : 0
  depends_on      = [ibm_iam_authorization_policy.kms_policy]
  create_duration = "30s"
}

# if using HPCS ,create a second IAM authorization that assigns the Viewer platform access in Hyper Protect Crypto Services .[Learn more](https://cloud.ibm.com/docs/secrets-manager?topic=secrets-manager-mng-data#using-byok)
resource "ibm_iam_authorization_policy" "secrets_manager_hpcs_policy" {
  count                       = local.create_cross_account_hpcs_auth_policy
  provider                    = ibm.kms
  source_service_account      = data.ibm_iam_account_settings.iam_account_settings[0].account_id
  source_service_name         = "secrets-manager"
  source_resource_group_id    = module.resource_group[0].resource_group_id
  target_service_name         = local.kms_service_name
  target_resource_instance_id = local.kms_instance_guid
  roles                       = ["Viewer"]
  description                 = "Allow all Secrets Manager instances in the resource group ${module.resource_group[0].resource_group_id} in the account ${data.ibm_iam_account_settings.iam_account_settings[0].account_id} to view from the ${local.kms_service_name} instance GUID ${local.kms_instance_guid}"
}

# workaround for https://github.com/IBM-Cloud/terraform-provider-ibm/issues/4478
resource "time_sleep" "wait_for_sm_hpcs_authorization_policy" {
  count           = local.create_cross_account_hpcs_auth_policy
  depends_on      = [ibm_iam_authorization_policy.secrets_manager_hpcs_policy]
  create_duration = "30s"
}


# KMS root key for Secrets Manager secret encryption
module "kms" {
  providers = {
    ibm = ibm.kms
  }
  count                       = var.existing_secrets_manager_crn != null || var.existing_secrets_manager_kms_key_crn != null ? 0 : 1 # no need to create any KMS resources if passing an existing key, or bucket
  source                      = "terraform-ibm-modules/kms-all-inclusive/ibm"
  version                     = "4.21.3"
  create_key_protect_instance = false
  region                      = local.kms_region
  existing_kms_instance_crn   = var.existing_kms_instance_crn
  key_ring_endpoint_type      = var.kms_endpoint_type
  key_endpoint_type           = var.kms_endpoint_type
  keys = [
    {
      key_ring_name     = local.kms_key_ring_name
      existing_key_ring = false
      keys = [
        {
          key_name                 = local.kms_key_name
          standard_key             = false
          rotation_interval_month  = 3
          dual_auth_delete_enabled = false
          force_delete             = true
        }
      ]
    }
  ]
}

########################################################################################################################
# Secrets Manager
########################################################################################################################

locals {
  parsed_existing_secrets_manager_crn = var.existing_secrets_manager_crn != null ? split(":", var.existing_secrets_manager_crn) : []
  secrets_manager_guid                = var.existing_secrets_manager_crn != null ? (length(local.parsed_existing_secrets_manager_crn) > 0 ? local.parsed_existing_secrets_manager_crn[7] : null) : module.secrets_manager.secrets_manager_guid
  secrets_manager_crn                 = var.existing_secrets_manager_crn != null ? var.existing_secrets_manager_crn : module.secrets_manager.secrets_manager_crn
  secrets_manager_region              = var.existing_secrets_manager_crn != null ? (length(local.parsed_existing_secrets_manager_crn) > 0 ? local.parsed_existing_secrets_manager_crn[5] : null) : module.secrets_manager.secrets_manager_region
}

module "secrets_manager" {
  depends_on               = [time_sleep.wait_for_authorization_policy, time_sleep.wait_for_sm_hpcs_authorization_policy]
  source                   = "../../modules/fscloud"
  existing_sm_instance_crn = var.existing_secrets_manager_crn
  resource_group_id        = var.existing_secrets_manager_crn == null ? module.resource_group[0].resource_group_id : data.ibm_resource_instance.existing_sm[0].resource_group_id
  region                   = var.region
  secrets_manager_name     = try("${local.prefix}-${var.secrets_manager_instance_name}", var.secrets_manager_instance_name)
  service_plan             = var.service_plan
  sm_tags                  = var.secrets_manager_tags
  is_hpcs_key              = local.is_hpcs_key
  # kms dependency
  kms_key_crn                       = local.kms_key_crn
  skip_kms_iam_authorization_policy = var.skip_kms_iam_authorization_policy || local.create_cross_account_auth_policy
  # event notifications dependency
  enable_event_notification        = var.enable_event_notifications
  existing_en_instance_crn         = var.existing_event_notifications_instance_crn
  skip_en_iam_authorization_policy = var.skip_event_notifications_iam_authorization_policy
  cbr_rules                        = var.cbr_rules
  skip_iam_authorization_policy    = var.skip_iam_authorization_policy
}

# Configure an IBM Secrets Manager IAM credentials engine for an existing IBM Secrets Manager instance.
module "iam_secrets_engine" {
  count                = var.iam_engine_enabled ? 1 : 0
  source               = "terraform-ibm-modules/secrets-manager-iam-engine/ibm"
  version              = "1.2.10"
  region               = local.secrets_manager_region
  iam_engine_name      = try("${local.prefix}-${var.iam_engine_name}", var.iam_engine_name)
  secrets_manager_guid = local.secrets_manager_guid
  endpoint_type        = "private"
}


# Configure an IBM Secrets Manager public certificate engine for an existing IBM Secrets Manager instance.
module "secrets_manager_public_cert_engine" {
  count   = var.public_cert_engine_enabled ? 1 : 0
  source  = "terraform-ibm-modules/secrets-manager-public-cert-engine/ibm"
  version = "1.0.3"
  providers = {
    ibm              = ibm
    ibm.secret-store = ibm
  }
  secrets_manager_guid         = local.secrets_manager_guid
  region                       = local.secrets_manager_region
  internet_services_crn        = var.public_cert_engine_internet_services_crn
  ibmcloud_cis_api_key         = var.ibmcloud_api_key
  dns_config_name              = var.public_cert_engine_dns_provider_config_name
  ca_config_name               = var.public_cert_engine_lets_encrypt_config_ca_name
  acme_letsencrypt_private_key = var.acme_letsencrypt_private_key
  service_endpoints            = "private"
}


# Configure an IBM Secrets Manager private certificate engine for an existing IBM Secrets Manager instance.
module "private_secret_engine" {
  count                     = var.private_cert_engine_enabled ? 1 : 0
  source                    = "terraform-ibm-modules/secrets-manager-private-cert-engine/ibm"
  version                   = "1.3.5"
  secrets_manager_guid      = local.secrets_manager_guid
  region                    = var.region
  root_ca_name              = var.private_cert_engine_config_root_ca_name
  root_ca_common_name       = var.private_cert_engine_config_root_ca_common_name
  root_ca_max_ttl           = var.private_cert_engine_config_root_ca_max_ttl
  intermediate_ca_name      = var.private_cert_engine_config_intermediate_ca_name
  certificate_template_name = var.private_cert_engine_config_template_name
  endpoint_type             = "private"
}

data "ibm_resource_instance" "existing_sm" {
  count      = var.existing_secrets_manager_crn == null ? 0 : 1
  identifier = var.existing_secrets_manager_crn
}

#######################################################################################################################
# Secrets Manager Event Notifications Configuration
#######################################################################################################################

locals {
  parsed_existing_en_instance_crn = var.existing_event_notifications_instance_crn != null ? split(":", var.existing_event_notifications_instance_crn) : []
  existing_en_guid                = length(local.parsed_existing_en_instance_crn) > 0 ? local.parsed_existing_en_instance_crn[7] : null
}

data "ibm_en_destinations" "en_destinations" {
  # if existing SM instance CRN is passed (!= null), then never do data lookup for EN destinations
  count         = var.existing_secrets_manager_crn == null && var.enable_event_notifications ? 1 : 0
  instance_guid = local.existing_en_guid
}

# workaround for https://github.com/IBM-Cloud/terraform-provider-ibm/issues/5533
resource "time_sleep" "wait_for_secrets_manager" {
  # if existing SM instance CRN is passed (!= null), then never work with EN
  count      = var.existing_secrets_manager_crn == null && var.enable_event_notifications ? 1 : 0
  depends_on = [module.secrets_manager]

  create_duration = "30s"
}

resource "ibm_en_topic" "en_topic" {
  # if existing SM instance CRN is passed (!= null), then never create EN topic
  count         = var.existing_secrets_manager_crn == null && var.enable_event_notifications ? 1 : 0
  depends_on    = [time_sleep.wait_for_secrets_manager]
  instance_guid = local.existing_en_guid
  name          = "Secrets Manager Topic"
  description   = "Topic for Secrets Manager events routing"
  sources {
    id = local.secrets_manager_crn
    rules {
      enabled           = true
      event_type_filter = "$.*"
    }
  }
}

resource "ibm_en_subscription_email" "email_subscription" {
  # if existing SM instance CRN is passed (!= null), then never create EN email subscription
  count          = var.existing_secrets_manager_crn == null && var.enable_event_notifications && length(var.event_notifications_email_list) > 0 ? 1 : 0
  instance_guid  = local.existing_en_guid
  name           = "Email for Secrets Manager Subscription"
  description    = "Subscription for Secret Manager Events"
  destination_id = [for s in toset(data.ibm_en_destinations.en_destinations[count.index].destinations) : s.id if s.type == "smtp_ibm"][0]
  topic_id       = ibm_en_topic.en_topic[count.index].topic_id
  attributes {
    add_notification_payload = true
    reply_to_mail            = var.event_notifications_reply_to_email
    reply_to_name            = "Secret Manager Event Notifications Bot"
    from_name                = var.event_notifications_from_email
    invited                  = var.event_notifications_email_list
  }
}
