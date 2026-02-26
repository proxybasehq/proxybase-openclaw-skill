name: proxybase-purchase
args:
  package_id:
    default: "us_residential_1gb"
  pay_currency:
    default: "usdcsol"

steps:
  - id: setup
    command: >
      bash {baseDir}/proxybase.sh register 2>&1 || true;
      echo '{"status":"ready"}'

  - id: list_packages
    command: >
      curl -s "${PROXYBASE_API_URL:-https://api.proxybase.xyz/v1}/packages"
        -H "X-API-Key: $PROXYBASE_API_KEY"
        --connect-timeout 10 --max-time 15

  - id: create_order
    command: >
      bash {baseDir}/proxybase.sh order "$package_id" "$pay_currency"

  - id: confirm_payment
    command: >
      echo "Please send payment to the address shown above. Once you have sent the crypto payment, approve this step to begin monitoring."
    approval: required

  - id: poll_active
    command: >
      ORDER_ID=$(echo "$PROXYBASE_CREATE_OUTPUT" | grep '^PROXYBASE_ORDER_ID=' | tail -1 | cut -d= -f2);
      if [ -z "$ORDER_ID" ]; then echo "ERROR: Could not extract order_id from create_order step"; exit 1; fi;
      bash {baseDir}/proxybase.sh poll "$ORDER_ID"
    env:
      PROXYBASE_CREATE_OUTPUT: $create_order.stdout
    condition: $confirm_payment.approved

  - id: ask_inject_gateway
    command: >
      echo "✅ Proxy is active. Would you like to inject this proxy globally into the OpenClaw Gateway configuration? Doing so will automatically restart the Gateway process."
    approval: required

  - id: inject_gateway
    command: >
      ORDER_ID=$(echo "$PROXYBASE_CREATE_OUTPUT" | grep '^PROXYBASE_ORDER_ID=' | tail -1 | cut -d= -f2);
      bash {baseDir}/proxybase.sh inject-gateway "$ORDER_ID"
    env:
      PROXYBASE_CREATE_OUTPUT: $create_order.stdout
    condition: $ask_inject_gateway.approved
