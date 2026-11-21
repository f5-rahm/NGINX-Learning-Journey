#!/bin/bash
# Remove the throwaway stack (containers and network). Keeps state/ (cookie secret, cookie jar).
docker rm -f zta-s7-edge zta-s7-sso zta-s7-idp zta-s7-app >/dev/null 2>&1
docker network rm zta-s7 >/dev/null 2>&1
echo "down"
