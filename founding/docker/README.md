# Vendored from zulip/docker-zulip

`entrypoint.sh` is copied verbatim from https://github.com/zulip/docker-zulip
(Apache-2.0, same licence as this repository).

## Why it is vendored rather than referenced

`Dockerfile.prod` builds a Zulip release tarball **from this working tree**, so
that a customer's edits actually reach production. Upstream's published image
(`ghcr.io/zulip/zulip-server`) cannot be used for that: deploying it would ship
stock Zulip and silently discard everything the customer changed. That exact
mistake shipped once already on another template.

Building the tarball ourselves means we also need the piece of docker-zulip that
turns a bare install into a container configurable by `SETTING_*` environment
variables — which is this script. It lives in the docker-zulip repository, not in
zulip/zulip, so there is nothing to reference at build time.

## Updating it

Re-copy from docker-zulip when bumping the pinned Zulip version, and diff it:
this script encodes assumptions about the install layout that change with it.
