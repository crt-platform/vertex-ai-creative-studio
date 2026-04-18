"""Session-based authentication middleware (replaces basic auth)."""
import base64
import secrets
from datetime import datetime, timedelta

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

_SKIP_PATHS = {"/health", "/status"}
_SESSION_COOKIE = "auth_session"
_SESSION_DURATION = timedelta(hours=24)

# In-memory session store (TODO: use Redis for production)
_SESSIONS = {}


class SessionAuthMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, username: str, password: str):
        super().__init__(app)
        self._username = username
        self._password = password

    async def dispatch(self, request: Request, call_next):
        if request.url.path in _SKIP_PATHS:
            return await call_next(request)

        # Check if valid session exists
        session_token = request.cookies.get(_SESSION_COOKIE)
        if session_token and self._validate_session(session_token):
            request.scope["SESSION_USER"] = self._username
            return await call_next(request)

        # No session - check Basic auth header
        auth = request.headers.get("Authorization", "")
        if auth.startswith("Basic "):
            if self._validate_basic_auth(auth[6:]):
                # Create session
                token = self._create_session()
                response = await call_next(request)
                response.set_cookie(
                    key=_SESSION_COOKIE,
                    value=token,
                    max_age=int(_SESSION_DURATION.total_seconds()),
                    httponly=True,
                    secure=True,
                    samesite="Lax"
                )
                request.scope["SESSION_USER"] = self._username
                return response

        # No valid auth - challenge
        return self._challenge()

    def _validate_basic_auth(self, encoded: str) -> bool:
        try:
            decoded = base64.b64decode(encoded).decode("utf-8")
            user, _, pwd = decoded.partition(":")
            return (
                secrets.compare_digest(user, self._username) and
                secrets.compare_digest(pwd, self._password)
            )
        except Exception:
            return False

    def _create_session(self) -> str:
        token = secrets.token_urlsafe(32)
        _SESSIONS[token] = {
            "user": self._username,
            "expires": datetime.utcnow() + _SESSION_DURATION
        }
        return token

    def _validate_session(self, token: str) -> bool:
        if token not in _SESSIONS:
            return False
        session = _SESSIONS[token]
        if datetime.utcnow() > session["expires"]:
            del _SESSIONS[token]
            return False
        return True

    @staticmethod
    def _challenge() -> Response:
        return Response(
            status_code=401,
            content="Authentication required",
            headers={"WWW-Authenticate": 'Basic realm="Creative Studio"'},
        )
