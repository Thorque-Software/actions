#!/bin/bash

set -euo pipefail

echo "Installing AWS CLI v2..."

# Ensure unzip is available
if ! command -v unzip &>/dev/null; then
  echo "Installing unzip..."
  sudo apt-get update -qq && sudo apt-get install -y unzip
fi

# Download and install
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/
sudo /tmp/aws/install

# Cleanup
rm -rf /tmp/awscliv2.zip /tmp/aws

echo "AWS CLI installed: $(aws --version)"
