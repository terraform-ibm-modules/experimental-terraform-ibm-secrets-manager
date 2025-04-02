data "ibm_sm_secrets" "secrets" {
  instance_id = var.instance_id
  region      = var.region
  #  crn:v1:bluemix:public:secrets-manager:us-south:a/abac0df06b644a9cabc6e44f55b3880e:b0b1b819-b7ae-4015-9caa-fbbd042b94cb::
  #  "b0b1b819-b7ae-4015-9caa-fbbd042b94cb"
}
