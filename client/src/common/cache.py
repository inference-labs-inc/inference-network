"""
Hybrid caching solution supporting both Memcached (Cloud Memorystore) and in-memory caching.
Automatically falls back to in-memory cache if Memcached is unavailable.
"""

import functools
import json
from abc import ABC, abstractmethod
from typing import Any, Callable, Optional

import requests
from cachetools import TTLCache
from pymemcache.client.base import Client as MemcacheClient
from pymemcache.exceptions import MemcacheError

from common.logging import get_logger

logger = get_logger("cache")


class CacheBackend(ABC):
    """Abstract base class for cache backends"""

    @abstractmethod
    def get(self, key: str) -> Optional[Any]:
        """Get value from cache"""
        pass

    @abstractmethod
    def set(self, key: str, value: Any, ttl: int = 300) -> bool:
        """Set value in cache with TTL in seconds"""
        pass

    @abstractmethod
    def delete(self, key: str) -> bool:
        """Delete value from cache"""
        pass

    @abstractmethod
    def exists(self, key: str) -> bool:
        """Check if key exists in cache"""
        pass

    @abstractmethod
    def clear(self) -> bool:
        """Clear all cache entries"""
        pass


class MemcachedCache(CacheBackend):
    """Memcached-based cache backend for Cloud Memorystore"""

    def __init__(
        self, memcached_host, memcached_port, connect_timeout=2.0, timeout=2.0
    ):
        self.client = MemcacheClient(
            (memcached_host, memcached_port),
            connect_timeout=connect_timeout,
            timeout=timeout,
        )

        # Test connection with a simple operation
        self.client.version()
        logger.debug(
            f"Successfully connected to Memcached at {memcached_host}:{memcached_port}"
        )

    def get(self, key: str) -> Optional[Any]:
        try:
            return self.client.get(key)
        except MemcacheError as e:
            logger.error(f"Memcached get error for key {key}: {e}")
            return None
        except Exception as e:
            logger.error(f"Unexpected error getting key {key}: {e}")
            return None

    def set(self, key: str, value: Any, ttl: int = 300) -> bool:
        try:
            # Memcached expects TTL as expire time (0 = never expire, >0 = seconds)
            self.client.set(key=key, value=value, expire=ttl)
            return True
        except MemcacheError as e:
            logger.error(f"Memcached set error for key {key}: {e}")
            return False
        except Exception as e:
            logger.error(f"Unexpected error setting key {key}: {e}")
            return False

    def delete(self, key: str) -> bool:
        try:
            self.client.delete(key)
            return True
        except MemcacheError as e:
            logger.error(f"Memcached delete error for key {key}: {e}")
            return False
        except Exception as e:
            logger.error(f"Unexpected error deleting key {key}: {e}")
            return False

    def exists(self, key: str) -> bool:
        try:
            # Memcached doesn't have a native exists operation
            # We need to get the value to check existence
            return self.client.get(key) is not None
        except MemcacheError as e:
            logger.error(f"Memcached exists error for key {key}: {e}")
            return False
        except Exception as e:
            logger.error(f"Unexpected error checking key {key}: {e}")
            return False

    def clear(self) -> bool:
        try:
            self.client.flush_all()
            return True
        except MemcacheError as e:
            logger.error(f"Memcached clear error: {e}")
            return False
        except Exception as e:
            logger.error(f"Unexpected error clearing cache: {e}")
            return False


class InMemoryCache(CacheBackend):
    """In-memory cache backend using cachetools"""

    def __init__(self, maxsize: int = 1000, default_ttl: int = 300):
        self.cache = TTLCache(maxsize=maxsize, ttl=default_ttl)
        logger.info(
            f"In-memory cache backend initialized (maxsize={maxsize}, ttl={default_ttl}s)"
        )

    def get(self, key: str) -> Optional[Any]:
        try:
            return self.cache.get(key)
        except Exception as e:
            logger.error(f"In-memory get error for key {key}: {e}")
            return None

    def set(self, key: str, value: Any, ttl: int = 300) -> bool:
        try:
            # Note: TTLCache uses a single TTL for all entries
            # For per-key TTL, you'd need a more complex implementation
            self.cache[key] = value
            return True
        except Exception as e:
            logger.error(f"In-memory set error for key {key}: {e}")
            return False

    def delete(self, key: str) -> bool:
        try:
            if key in self.cache:
                del self.cache[key]
            return True
        except Exception as e:
            logger.error(f"In-memory delete error for key {key}: {e}")
            return False

    def exists(self, key: str) -> bool:
        return key in self.cache

    def clear(self) -> bool:
        try:
            self.cache.clear()
            return True
        except Exception as e:
            logger.error(f"In-memory clear error: {e}")
            return False


class CloudflareKVCache(CacheBackend):
    """
    Cloudflare Workers KV cache backend
    """

    def __init__(
        self,
        account_id: str,
        namespace_id: str,
        api_token: str,
        timeout: float = 5.0,
    ):
        self.account_id = account_id
        self.namespace_id = namespace_id
        self.api_token = api_token
        self.timeout = timeout
        self.base_url = f"https://api.cloudflare.com/client/v4/accounts/{account_id}/storage/kv/namespaces/{namespace_id}"
        self.headers = {
            "Authorization": f"Bearer {api_token}",
            "Content-Type": "application/json",
        }
        logger.info(
            f"Cloudflare KV cache backend initialized (namespace: {namespace_id})"
        )

    def get(self, key: str) -> Optional[Any]:
        try:
            url = f"{self.base_url}/values/{key}"
            response = requests.get(url, headers=self.headers, timeout=self.timeout)

            if response.status_code == 404:
                return None

            if response.status_code != 200:
                logger.error(
                    f"Cloudflare KV get error for key {key}: HTTP {response.status_code}"
                )
                return None

            # Cloudflare KV stores raw bytes, deserialize with pickle
            return json.loads(response.content)

        except requests.RequestException as e:
            logger.error(f"Cloudflare KV get error for key {key}: {e}")
            return None
        except Exception as e:
            logger.error(f"Unexpected error getting key {key}: {e}")
            return None

    def set(self, key: str, value: Any, ttl: int = 300) -> bool:
        try:
            # Cloudflare KV uses metadata and expiration_ttl
            params = {"expiration_ttl": ttl} if ttl > 0 else {}

            response = requests.put(
                f"{self.base_url}/values/{key}",
                data=json.dumps(value),
                headers=self.headers,
                params=params,
                timeout=self.timeout,
            )

            if response.status_code not in (200, 201):
                logger.error(
                    f"Cloudflare KV set error for key {key}: HTTP {response.status_code}"
                )
                return False

            return True

        except requests.RequestException as e:
            logger.error(f"Cloudflare KV set error for key {key}: {e}")
            return False
        except Exception as e:
            logger.error(f"Unexpected error setting key {key}: {e}")
            return False

    def delete(self, key: str) -> bool:
        try:
            url = f"{self.base_url}/values/{key}"
            response = requests.delete(url, headers=self.headers, timeout=self.timeout)

            if response.status_code not in (200, 404):
                logger.error(
                    f"Cloudflare KV delete error for key {key}: HTTP {response.status_code}"
                )
                return False

            return True

        except requests.RequestException as e:
            logger.error(f"Cloudflare KV delete error for key {key}: {e}")
            return False
        except Exception as e:
            logger.error(f"Unexpected error deleting key {key}: {e}")
            return False

    def exists(self, key: str) -> bool:
        try:
            url = f"{self.base_url}/values/{key}"
            response = requests.head(url, headers=self.headers, timeout=self.timeout)
            return response.status_code == 200

        except requests.RequestException as e:
            logger.error(f"Cloudflare KV exists error for key {key}: {e}")
            return False
        except Exception as e:
            logger.error(f"Unexpected error checking key {key}: {e}")
            return False

    def clear(self) -> bool:
        """
        Clear all entries in the namespace.
        Note: This lists all keys and deletes them one by one.
        For production use, consider using Cloudflare's bulk delete API.
        """
        try:
            # List all keys in the namespace
            url = f"{self.base_url}/keys"
            response = requests.get(url, headers=self.headers, timeout=self.timeout)

            if response.status_code != 200:
                logger.error(f"Cloudflare KV clear error: HTTP {response.status_code}")
                return False

            data = response.json()
            keys = [item["name"] for item in data.get("result", [])]

            # Delete each key
            for key in keys:
                self.delete(key)

            logger.info(f"Cleared {len(keys)} keys from Cloudflare KV")
            return True

        except requests.RequestException as e:
            logger.error(f"Cloudflare KV clear error: {e}")
            return False
        except Exception as e:
            logger.error(f"Unexpected error clearing cache: {e}")
            return False


class NoOpCache(CacheBackend):
    """No-op cache backend that disables caching entirely"""

    def __init__(self):
        logger.info("Caching is disabled (NoOpCache)")

    def get(self, key: str) -> Optional[Any]:
        return None

    def set(self, key: str, value: Any, ttl: int = 300) -> bool:
        return True

    def delete(self, key: str) -> bool:
        return True

    def exists(self, key: str) -> bool:
        return False

    def clear(self) -> bool:
        return True


def get_cache(
    memcached_host: Optional[str] = None,
    memcached_port: int = 11211,
    cloudflare_account_id: Optional[str] = None,
    cloudflare_namespace_id: Optional[str] = None,
    cloudflare_api_token: Optional[str] = None,
    connect_timeout: float = 2.0,
    timeout: float = 2.0,
    fallback_maxsize: int = 1000,
    fallback_ttl: int = 300,
    enable_cache: bool = True,
) -> CacheBackend:
    """
    Factory function that returns a cache backend instance.
    Priority order: Cloudflare KV > Memcached > In-memory cache.

    Args:
        memcached_host: Memcached host (e.g., IP address from Memorystore)
        memcached_port: Memcached port (default: 11211)
        cloudflare_account_id: Cloudflare account ID for KV
        cloudflare_namespace_id: Cloudflare KV namespace ID
        cloudflare_api_token: Cloudflare API token with KV permissions
        connect_timeout: Connection timeout in seconds
        timeout: Operation timeout in seconds
        fallback_maxsize: Max items for in-memory cache fallback
        fallback_ttl: Default TTL for in-memory cache fallback
        enable_cache: If False, returns NoOpCache that disables caching entirely

    Returns:
        CacheBackend: CloudflareKVCache, MemcachedCache, InMemoryCache, or NoOpCache instance
    """
    # If caching is disabled, return no-op cache
    if not enable_cache:
        return NoOpCache()

    # Try Cloudflare KV first if configuration is provided
    if cloudflare_account_id and cloudflare_namespace_id and cloudflare_api_token:
        try:
            kv_cache = CloudflareKVCache(
                account_id=cloudflare_account_id,
                namespace_id=cloudflare_namespace_id,
                api_token=cloudflare_api_token,
                timeout=timeout,
            )
            # Test connection with a simple operation
            kv_cache.exists("__test_connection__")
            logger.info("Successfully connected to Cloudflare KV")
            return kv_cache

        except requests.RequestException as e:
            logger.warning(
                f"Failed to connect to Cloudflare KV: {e}. Trying Memcached..."
            )
        except Exception as e:
            logger.warning(
                f"Unexpected error connecting to Cloudflare KV: {e}. Trying Memcached..."
            )

    # Try Memcached if configuration is provided
    if memcached_host:
        try:
            return MemcachedCache(
                memcached_host, memcached_port, connect_timeout, timeout
            )

        except MemcacheError as e:
            logger.warning(
                f"Failed to connect to Memcached: {e}. Falling back to in-memory cache."
            )
        except Exception as e:
            logger.warning(
                f"Unexpected error connecting to Memcached: {e}. Falling back to in-memory cache."
            )

    # Fallback to in-memory cache
    logger.info(
        "Using in-memory cache (no external cache configuration or connection failed)"
    )
    return InMemoryCache(maxsize=fallback_maxsize, default_ttl=fallback_ttl)


def cached_method(ttl: int = 86400, key_prefix: Optional[str] = None):
    """
    Decorator for caching method results.

    The cache key is automatically generated from:
    - key_prefix (or method name if not provided)
    - method arguments (args and kwargs)

    Usage:
        class MyClass:
            def __init__(self, cache: CacheBackend):
                self.cache = cache

            @cached_method(ttl=600, key_prefix="operator_split")
            def get_operator_split(self, operator: str) -> int:
                # expensive operation
                return result

    Args:
        ttl: Time-to-live for cached value in seconds
        key_prefix: Optional prefix for cache key (defaults to method name)

    Returns:
        Decorated method that uses caching
    """

    def decorator(method: Callable) -> Callable:
        method_name = method.__name__
        prefix = key_prefix or method_name

        @functools.wraps(method)
        def wrapper(self, *args, **kwargs):
            # Check if instance has a cache attribute
            if not hasattr(self, "cache"):
                # No cache available, just call the method
                return method(self, *args, **kwargs)

            cache: CacheBackend = self.cache

            # Generate cache key from method name and arguments
            # Convert args and kwargs to a hashable representation
            try:
                # Try to create a simple string key from arguments
                args_str = "_".join(str(arg) for arg in args)
                kwargs_str = "_".join(f"{k}={v}" for k, v in sorted(kwargs.items()))
                key_parts = [prefix]
                if args_str:
                    key_parts.append(args_str)
                if kwargs_str:
                    key_parts.append(kwargs_str)
                cache_key = ":".join(key_parts)
            except Exception as e:
                logger.warning(f"Failed to generate cache key for {method_name}: {e}")
                # Fall back to calling method without caching
                return method(self, *args, **kwargs)

            # Try to get from cache
            cached_value = cache.get(cache_key)
            if cached_value is not None:
                logger.debug(f"Cache hit for {cache_key}")
                return cached_value

            # Cache miss - call the method
            logger.debug(f"Cache miss for {cache_key}")
            result = method(self, *args, **kwargs)

            # Store in cache
            cache.set(cache_key, result, ttl=ttl)

            return result

        return wrapper

    return decorator
