# Keycloak Role Setup Guide

This guide explains how to configure roles in your `barbershop-realm` to secure your applications.

## 1. Create Realm Roles

1. Log in to Keycloak Admin Console (`http://localhost:8080`).
2. Select **barbershop-realm**.
3. Go to **Realm roles** in the left menu.
4. Click **Create role** and add the following roles:

| Role Name | Description |
|-----------|-------------|
| `admin` | Full access to all services and operations. |
| `map-viewer` | Read-only access to map tiles (Tileserver). |
| `data-viewer` | Read-only access to places data (Scraper API). |
| `data-editor` | Ability to create, update, and delete places data. |

## 2. Assign Roles to Users

1. Go to **Users** in the left menu.
2. Click on a user (or create a new one).
3. Go to the **Role mapping** tab.
4. Click **Assign role**.
5. Select the appropriate roles (e.g., `map-viewer` for a regular user).
6. Click **Assign**.

## 3. Verify Role Mapping in Token

To ensure Envoy can read the roles, they must be present in the JWT access token.

1. Go to **Client scopes**.
2. Click on `roles`.
3. Ensure **Include in token scope** is ON.
4. Go to **Mappers** tab.
5. Ensure there is a mapper for `realm roles` (usually default).
   - **Name**: `realm roles`
   - **Mapper Type**: `User Realm Role`
   - **Token Claim Name**: `realm_access.roles`
   - **Add to access token**: ON

## 4. Example User Setups

### The "Map Viewer" User
- **Roles**: `map-viewer`
- **Access**: Can see the map, but cannot see place details or edit anything.

### The "Staff" User
- **Roles**: `map-viewer`, `data-viewer`, `data-editor`
- **Access**: Can see map, see details, and edit data.

### The "Admin" User
- **Roles**: `admin`
- **Access**: Full access to everything.
