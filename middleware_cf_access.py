"""Cloudflare Access JWT authentication middleware."""
import logging
from functools import lru_cache

import jwt
from jwt import PyJWKClient, ExpiredSignatureError, InvalidAudienceError, DecodeError
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse

from config import default as config

logger = logging.getLogger(__name__)

_CF_JWT_HEADER = "CF-Access-Jwt-Assertion"
_SKIP_PATHS = {"/health", "/status"}


@lru_cache(maxsize=1)
def _get_jwks_client() -> PyJWKClient:
    return PyJWKClient(f"https://{config.Default.CF_TEAM_DOMAIN}/cdn-cgi/access/certs")


def _validate_cf_jwt(token: str) -> dict:
    client = _get_jwks_client()
    signing_key = client.get_signing_key_from_jwt(token)
    return jwt.decode(
        token,
        signing_key.key,
        algorithms=["RS256"],
        audience=config.Default.CF_AUD,
        issuer=f"https://{config.Default.CF_TEAM_DOMAIN}",
        options={"require": ["exp", "aud", "iss", "email"]},
    )


class CloudflareAccessMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        if request.url.path in _SKIP_PATHS:
            return await call_next(request)

        token = request.headers.get(_CF_JWT_HEADER)
        if not token:
            return JSONResponse(status_code=401, content={"detail": "Missing Cloudflare Access token"})

        try:
            claims = _validate_cf_jwt(token)
        except ExpiredSignatureError:
            return JSONResponse(status_code=401, content={"detail": "Cloudflare Access token expired"})
        except InvalidAudienceError:
            return JSONResponse(status_code=403, content={"detail": "Cloudflare Access token audience invalid"})
        except (DecodeError, Exception) as exc:
            logger.warning("CF Access JWT validation failed: %s", type(exc).__name__)
            return JSONResponse(status_code=401, content={"detail": "Cloudflare Access token invalid"})

        request.scope["CF_USER_EMAIL"] = claims.get("email", "")
        return await call_next(request)
