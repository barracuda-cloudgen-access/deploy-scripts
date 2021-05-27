# AWS VPN Demo

## Requirements

- Bash
- Git
- Openssl
- AWS Cli

Check the [Troubleshoot](##troubleshoot) section if you encounter issues

## How-to

1. Create Certificate Authority, Server and 1x Client certificates using easy-rsa:

    ```sh
    git clone https://github.com/OpenVPN/easy-rsa.git
    cd easy-rsa/easyrsa3
    ./easyrsa init-pki
    export EASYRSA_BATCH=1
    ./easyrsa build-ca nopass
    ./easyrsa build-server-full server nopass
    ./easyrsa build-client-full client1.vpn.example nopass
    ```

1. Import server and client certificates to AWS ACM. Run once for each region:

    ```sh
    # Set variables
    REGION=us-east-1

    # Import server certificate
    aws acm import-certificate \
        --private-key fileb://pki/private/server.key \
        --certificate fileb://pki/issued/server.crt \
        --certificate-chain fileb://pki/ca.crt \
        --tags Key=Name,Value=aws-vpn-demo-server \
        --region "${REGION}"

    # Import client certificate
    aws acm import-certificate \
        --private-key fileb://pki/private/client1.vpn.example.key \
        --certificate fileb://pki/issued/client1.vpn.example.crt \
        --certificate-chain fileb://pki/ca.crt \
        --tags Key=Name,Value=aws-vpn-demo-client1 \
        --region "${REGION}"
    ```

1. Get the `CertificateArn`'s to use on next step:

    ```sh
    # Set variables
    REGION=us-east-1

    aws acm list-certificates --region "${REGION}"
    ```

1. Deploy the cloudformation stack(s) using the `aws-vpn-demo.yaml` template. Run once for each region.

1. Create the vpn client configuration. Run once for each region:

    ```sh
    # Set variables
    REGION=us-east-1
    VPN_PROFILE_PATH="${HOME}/aws-vpn-demo/${REGION}"
    CLIENT_VPN_ENDPOINT_ID="$(aws ec2 describe-client-vpn-endpoints \
        --query 'ClientVpnEndpoints[*] | [?Description==`AWS VPN Demo`].ClientVpnEndpointId' \
        --output text \
        --region "${REGION}")"

    # Create profile directory
    mkdir -pv "${VPN_PROFILE_PATH}"

    # Copy client certificates
    cp -v pki/private/client1.vpn.example.key "${VPN_PROFILE_PATH}/"
    cp -v pki/issued/client1.vpn.example.crt "${VPN_PROFILE_PATH}/"

    # Get the openvpn configuration
    aws ec2 export-client-vpn-client-configuration \
        --output text \
        --client-vpn-endpoint-id "${CLIENT_VPN_ENDPOINT_ID}" \
        --region "${REGION}" \
        > "${VPN_PROFILE_PATH}/client.ovpn"

    # Append required keys
    echo "key ${VPN_PROFILE_PATH}/client1.vpn.example.key" >> "${VPN_PROFILE_PATH}/client.ovpn"
    echo "cert ${VPN_PROFILE_PATH}/client1.vpn.example.crt" >> "${VPN_PROFILE_PATH}/client.ovpn"
    ```

1. Download and install [OpenVPN Connect](https://openvpn.net/download-open-vpn/)

1. Add the created profiles to the OpenVPN Connect client and connect

    - Connecting multiple profiles at the same time requires that the subnets from the different regions do not overlapp

1. Check the `InternalURL` Cloudformation output on each region and test that you can reach the web server

## Troubleshoot

- Software versions used:

  - GNU bash, version 5.1.4(1)-release (x86_64-apple-darwin19.6.0)
  - git version 2.30.0
  - Openssl: OpenSSL 1.1.1k  25 Mar 2021
  - AWS cli: aws-cli/2.2.3 Python/3.8.8 Darwin/19.6.0 exe/x86_64 prompt/off

- Cannot connect to VPN

  - Check [Unable to resolve Client VPN endpoint DNS name](https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/troubleshooting.html#resolve-host-name)
