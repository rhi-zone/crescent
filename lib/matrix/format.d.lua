-- Matrix client-server API types
-- https://spec.matrix.org/v1.11/client-server-api/

--:: matrix_server = { host: string }

-- matrix_identifier covers user, third-party, and phone identifiers
-- TODO: v3 gap — union over specific identifier types not yet supported
--:: matrix_identifier = { type: string }

-- https://spec.matrix.org/v1.11/client-server-api/#getwell-knownmatrixclient
--:: matrix_homeserver_info = { base_url: string }
--:: matrix_identity_server_info = { base_url: string }
--:: matrix_server_discovery_info = { ["m.homeserver"]: matrix_homeserver_info, ["m.identity_server"]: matrix_identity_server_info }

-- https://spec.matrix.org/v1.11/client-server-api/#getwell-knownmatrixsupport
--:: matrix_contact = { email_address?: string, matrix_id?: string, role: string }
--:: matrix_server_support_info = { contacts?: { [number]: matrix_contact }, support_page?: string }

-- https://spec.matrix.org/v1.11/client-server-api/#get_matrixclientversions
--:: matrix_versions = { unstable_features?: { [string]: boolean }, versions: { [number]: string } }

-- matrix_role enum values: "m.role.admin", "m.role.security"
--:: matrix_role = string

-- https://spec.matrix.org/v1.11/client-server-api/#authentication-types
-- matrix_authentication_type enum values: "m.login.password", "m.login.recaptcha"
--:: matrix_authentication_type = string

--:: matrix_session_id = string

--:: matrix_threepid_credentials = { sid: string, client_secret: string, id_server?: string, id_access_token?: string }

-- https://spec.matrix.org/v1.11/client-server-api/#password-based
--:: matrix_password_authentication_request = { type: string, identifier: matrix_identifier, password: string, session: string }

-- https://spec.matrix.org/v1.11/client-server-api/#google-recaptcha
--:: matrix_recaptcha_authentication_request = { type: string, response: string, session: string }

-- https://spec.matrix.org/v1.11/client-server-api/#single-sign-on
--:: matrix_sso_authentication_request = { type: string }

-- https://spec.matrix.org/v1.11/client-server-api/#email-based-identity--homeserver
--:: matrix_email_authentication_request = { type: string, threepid_creds: matrix_threepid_credentials, session: string }

-- https://spec.matrix.org/v1.11/client-server-api/#phone-numbermsisdn-based-identity--homeserver
--:: matrix_msisdn_authentication_request = { type: string, threepid_creds: matrix_threepid_credentials, session: string }

-- https://spec.matrix.org/v1.11/client-server-api/#dummy-auth
--:: matrix_dummy_authentication_request = { type: string }

-- https://spec.matrix.org/v1.11/client-server-api/#token-authenticated-registration
-- only valid on the /register endpoint
--:: matrix_registration = { token: string, session: string }

-- TODO: v3 gap — matrix_identifier type is referenced but not defined here;
-- it comes from the Matrix identifier spec and needs its own declaration.
-- TODO: v3 gap — union alias matrix_authentication_request over the 6 request
-- types is not expressible until crescent supports cross-declaration union aliases.
