# Same image pins as infra/envs/preprod.tfvars.
images = {
  postgres           = "postgres:17.12-bookworm@sha256:40865bc877a289da75963d97d72b59633f639fc5af7a4e856bfa3714cae5b536"
  midnight_node      = "midnightntwrk/midnight-node:2.1.101@sha256:0c1ad548d523c1109aa1f16daab1bf72dcb78c7e17b8a8c6d97424ad0eba7b8a"
  indexer_standalone = "midnightntwrk/indexer-standalone:4.4.101@sha256:119f35db548ba1c390845f215bb1e928e73038bef7c315825aee0461bd54499d"
}
