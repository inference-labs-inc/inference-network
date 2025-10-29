from unittest.mock import Mock, patch

import pytest

from common.cache import (
    CloudflareKVCache,
    InMemoryCache,
    MemcachedCache,
    NoOpCache,
    cached_method,
    get_cache,
)
from common.config import CacheConfig


class TestBackends:

    def test_in_memory_cache(self):
        """Test cache initialization with custom parameters."""
        cache = get_cache(
            CacheConfig(
                disable=False,
            )
        )
        assert isinstance(cache, InMemoryCache)

        assert cache.exists("test_key") is False
        assert cache.set("test_key", "test_value", ttl=60) is True
        assert cache.exists("test_key") is True
        assert cache.get("test_key") == "test_value"
        assert cache.delete("test_key") is True
        assert cache.get("test_key") is None

    @patch("common.cache.MemcacheClient")
    def test_memcached(self, mock_client_class):
        """Test Memcached initialization."""
        mock_client = Mock()
        mock_client.version.return_value = b"1.6.0"
        mock_client_class.return_value = mock_client
        mock_client.get.return_value = "test_value"

        cache = get_cache(
            CacheConfig(
                disable=False,
                memcached_host="localhost",
                memcached_port=11211,
            )
        )
        assert isinstance(cache, MemcachedCache)

        # Set a value
        assert cache.set("test_key", "test_value", ttl=60) is True
        mock_client.set.assert_called_once_with(
            key="test_key", value="test_value", expire=60
        )

        # Get the value
        result = cache.get("test_key")
        assert result == "test_value"
        mock_client.get.assert_called_once_with("test_key")

        # Delete the key
        assert cache.delete("test_key") is True
        mock_client.delete.assert_called_once_with("test_key")

        # Test MemcacheError handling on get
        from pymemcache.exceptions import MemcacheError

        mock_client.get.side_effect = MemcacheError("Connection error")
        # Should return None on error, not raise exception
        assert cache.get("test_key") is None

    @patch("common.cache.requests.get")
    @patch("common.cache.requests.put")
    @patch("common.cache.requests.delete")
    @patch("common.cache.requests.head")
    def test_cloudflare_kv_cache(self, mock_head, mock_delete, mock_put, mock_get):
        """Test successful get operation."""

        cache = get_cache(
            CacheConfig(
                disable=False,
                cloudflare_account_id="acc",
                cloudflare_namespace_id="ns",
                cloudflare_api_token="token",
            )
        )
        assert isinstance(cache, CloudflareKVCache)

        mock_response = Mock()

        # Key does not exist
        mock_response.status_code = 404
        mock_get.return_value = mock_response
        cache = CloudflareKVCache("acc", "ns", "token")
        result = cache.get("nonexistent")
        assert result is None
        assert mock_get.call_count == 1

        # Get the value
        mock_response.status_code = 200
        mock_response.content = b'"test_value"'
        mock_get.return_value = mock_response
        result = cache.get("test_key")
        assert result == "test_value"
        assert mock_get.call_count == 2

        # Set the value
        mock_response.status_code = 200
        mock_put.return_value = mock_response
        cache = CloudflareKVCache("acc", "ns", "token")
        result = cache.set("test_key", "test_value", ttl=60)
        assert result is True
        mock_put.assert_called_once()

        # Delete the key
        mock_response.status_code = 200
        mock_delete.return_value = mock_response
        cache = CloudflareKVCache("acc", "ns", "token")
        result = cache.delete("test_key")
        assert result is True
        mock_delete.assert_called_once()

    def test_no_op_cache(self):
        """Test NoOpCache initialization."""
        cache = get_cache(CacheConfig(disable=True))
        assert isinstance(cache, NoOpCache)
        assert cache.get("any_key") is None
        assert cache.exists("any_key") is False
        assert cache.delete("any_key") is True
        assert cache.clear() is True
        assert cache.set("key", "value") is True
        assert cache.get("key") is None


class TestCachedMethodDecorator:
    """Tests for the cached_method decorator."""

    class SomeClass:
        def __init__(self, cache=None):
            self.call_count = 0
            if cache:
                self.cache = cache

        @cached_method(ttl=60, key_prefix="test")
        def method(self, arg1: str, arg2: int, kwarg1: str = "default") -> str:
            self.call_count += 1
            return f"result_{arg1}_{arg2}_{kwarg1}"

    def test_works_without_cache_attribute(self):
        """Test that decorator works when object has no cache attribute."""

        obj = self.SomeClass()

        # Should work without caching
        result1 = obj.method("value1", 42, kwarg1="kwarg")
        assert result1 == "result_value1_42_kwarg"
        assert obj.call_count == 1

        # Should call method again (no caching)
        result2 = obj.method("value1", 42, kwarg1="kwarg")
        assert result2 == "result_value1_42_kwarg"
        assert obj.call_count == 2

    def test_handles_multiple_arguments(self):
        """Test caching with multiple arguments."""
        cache = get_cache(CacheConfig(disable=False))
        assert isinstance(cache, InMemoryCache)
        cache.clear()

        obj = self.SomeClass(cache=cache)

        # First call
        result1 = obj.method("a", 1, kwarg1="x")
        assert result1 == "result_a_1_x"
        assert obj.call_count == 1

        # Same args - should use cache
        result2 = obj.method("a", 1, kwarg1="x")
        assert result2 == "result_a_1_x"
        assert obj.call_count == 1

        # Different args - should execute
        result3 = obj.method("a", 2, kwarg1="x")
        assert result3 == "result_a_2_x"
        assert obj.call_count == 2
