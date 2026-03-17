--:: http_response = { status?: number, status_text?: string, headers: { [string]: string }, body?: string }

--:: http_request = { method: string, path: string, params: { [string]: string }, version: number, headers: { [string]: string }, body: string }

--:: http_client_request = { method: string, host: string, port?: number, path: string, headers: { [string]: string }, body: string }

--:: http_client_response = { version: number, status: number, status_text: string, headers: { [string]: string }, body: string }
