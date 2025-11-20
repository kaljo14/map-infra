# Keycloak Client Configuration Guide

This guide explains how to configure a Keycloak client for use with the Envoy authentication setup.

## Step 1: Create a New Client

1. Log into your Keycloak Admin Console
2. Select your realm (or create a new one)
3. Navigate to **Clients** → **Create**

## Step 2: Client Settings

Configure the following settings:

### Basic Settings
- **Client ID**: `your-app-client` (use this in Envoy config)
- **Client Protocol**: `openid-connect`
- **Access Type**: `public` or `confidential` (depending on your needs)

### Capability Config
- **Client authentication**: ON (if using confidential)
- **Authorization**: OFF (unless you need fine-grained authorization)
- **Standard flow**: ON
- **Direct access grants**: ON
- **Implicit flow**: OFF (not recommended)
- **Service accounts**: ON (if using confidential)

### Valid Redirect URIs
Add your application URLs:
```
https://your-app.example.com/*
http://localhost:3000/*  (for development)
```

### Web Origins
Add CORS origins:
```
https://your-app.example.com
http://localhost:3000  (for development)
```

## Step 3: Get Client Credentials (if confidential)

1. Go to the **Credentials** tab
2. Copy the **Client Secret**
3. Store this securely (you may need it for certain flows)

## Step 4: Configure Token Settings

Go to **Advanced Settings**:

- **Access Token Lifespan**: 5 minutes (default)
- **Client Session Idle**: 30 minutes
- **Client Session Max**: 10 hours

## Step 5: Add Audience Mapper (Important!)

This ensures the JWT has the correct audience claim:

1. Go to **Client Scopes** tab
2. Click on `your-app-client-dedicated`
3. Click **Add mapper** → **By configuration**
4. Select **Audience**
5. Configure:
   - **Name**: `audience-mapper`
   - **Included Client Audience**: `your-app-client`
   - **Add to access token**: ON

## Step 6: Get JWKS URI

Your JWKS URI will be:
```
https://YOUR_KEYCLOAK_URL/realms/YOUR_REALM/protocol/openid-connect/certs
```

Use this in the Envoy configuration.

## Step 7: Test Token Generation

You can test token generation using curl:

```bash
curl -X POST 'https://YOUR_KEYCLOAK_URL/realms/YOUR_REALM/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'client_id=your-app-client' \
  -d 'client_secret=YOUR_CLIENT_SECRET' \
  -d 'grant_type=client_credentials'
```

Or for user authentication:

```bash
curl -X POST 'https://YOUR_KEYCLOAK_URL/realms/YOUR_REALM/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'client_id=your-app-client' \
  -d 'username=YOUR_USERNAME' \
  -d 'password=YOUR_PASSWORD' \
  -d 'grant_type=password'
```

## Step 8: Update Envoy Configuration

Update the following values in `envoy/envoy-config.yaml`:

- `YOUR_KEYCLOAK_URL`: Your Keycloak base URL
- `YOUR_REALM`: Your realm name
- `YOUR_CLIENT_ID`: The client ID you created
- `YOUR_KEYCLOAK_SERVICE_NAME`: Keycloak service name in K8s
- `YOUR_NAMESPACE`: Namespace where Keycloak is deployed

## Testing the Setup

1. Get a valid JWT token from Keycloak
2. Make a request to your application with the token:

```bash
curl -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  https://your-app.example.com/api/endpoint
```

3. Without a token, you should receive a 401 Unauthorized
4. With a valid token, the request should reach your application

## Troubleshooting

### 401 Unauthorized
- Check that the token is valid and not expired
- Verify the issuer matches your Keycloak realm
- Ensure the audience claim is present in the token

### JWKS Fetch Errors
- Verify Envoy can reach Keycloak
- Check DNS resolution in the cluster
- Verify TLS certificates if using HTTPS

### Token Not Forwarded
- Ensure `forward: true` is set in Envoy JWT config
- Check that your application is reading the Authorization header
