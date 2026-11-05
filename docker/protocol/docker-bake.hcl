# The protocol-ops image on a base built from the same commit's Dockerfile.base,
# so its toolchain is the one `.github/foundry-versions.env` pins at that commit
# rather than whatever `ghcr.io/matter-labs/protocol-ops-base:latest` was last
# built from. build-docker.yaml builds with it and sets the tag, labels, build
# args and caches. Locally, for `./protocol-ops.sh --tag local`:
#
#   docker buildx bake -f docker/protocol/docker-bake.hcl --load \
#     --set protocol.tags=ghcr.io/matter-labs/protocol-ops:local

group "default" {
  targets = ["protocol"]
}

target "base" {
  context    = "."
  dockerfile = "docker/protocol/Dockerfile.base"
  platforms  = ["linux/amd64"]
}

target "protocol" {
  context    = "."
  dockerfile = "docker/protocol/Dockerfile"
  platforms  = ["linux/amd64"]
  contexts = {
    "protocol-ops-base" = "target:base"
  }
  args = {
    BUILD_BASE_IMAGE = "protocol-ops-base"
  }
}
