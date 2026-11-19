# Uses the terraform ruleset bundled with tflint (pinned via the tflint version in CI, v0.66.0),
# with every rule on: naming, typed + documented variables/outputs, pinned providers, standard
# module structure, unused declarations.
config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}
