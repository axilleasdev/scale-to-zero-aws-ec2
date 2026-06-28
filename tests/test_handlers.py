"""Unit tests for Lambda handlers (mocked AWS calls)."""

import datetime as dt
import os
from unittest.mock import MagicMock, patch

import pytest


# ─── auto-stop tests ────────────────────────────────────────────────────────


@pytest.fixture(autouse=True)
def _auto_stop_env(monkeypatch):
    monkeypatch.setenv("INSTANCE_ID", "i-test123")
    monkeypatch.setenv("IDLE_WINDOW_MIN", "15")
    monkeypatch.setenv("IDLE_THRESHOLD_PPS", "3.0")
    monkeypatch.setenv("MIN_UPTIME_MIN", "10")


def _import_auto_stop():
    """Import fresh to pick up env vars."""
    import importlib
    import lambda_.auto_stop.handler as mod  # noqa: N813
    importlib.reload(mod)
    return mod


class TestAutoStop:
    @patch("boto3.client")
    def test_skip_when_stopped(self, mock_client):
        ec2 = MagicMock()
        ec2.describe_instances.return_value = {
            "Reservations": [{"Instances": [{"State": {"Name": "stopped"}, "LaunchTime": dt.datetime.now(dt.timezone.utc)}]}]
        }
        mock_client.return_value = ec2

        # Re-import to use mocked client
        with patch.dict("sys.modules", {}):
            import importlib
            import sys
            # Clear cached module
            for key in list(sys.modules.keys()):
                if "auto_stop" in key or "auto-stop" in key:
                    del sys.modules[key]

            sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda", "auto-stop"))
            import handler
            importlib.reload(handler)
            handler.ec2 = ec2
            handler.cloudwatch = MagicMock()

            result = handler.lambda_handler({}, None)
            assert result["action"] == "skip"
            assert "stopped" in result["reason"]


# ─── dns-updater tests ──────────────────────────────────────────────────────


class TestDnsUpdater:
    def test_cloudfront_mode_updates_origin(self, monkeypatch):
        monkeypatch.setenv("INSTANCE_ID", "i-test123")
        monkeypatch.setenv("MODE", "cloudfront")
        monkeypatch.setenv("DISTRIBUTION_IDS", "EXXXTEST")
        monkeypatch.setenv("ORIGIN_ID", "origin-ec2")

        import sys
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda", "dns-updater"))

        for key in list(sys.modules.keys()):
            if "dns_updater" in key or "handler" in key:
                del sys.modules[key]

        import handler
        import importlib
        importlib.reload(handler)

        # Mock EC2
        mock_ec2 = MagicMock()
        mock_ec2.describe_instances.return_value = {
            "Reservations": [{"Instances": [{"PublicIpAddress": "1.2.3.4"}]}]
        }
        handler.ec2 = mock_ec2

        # Mock CloudFront
        mock_cf = MagicMock()
        mock_cf.get_distribution_config.return_value = {
            "ETag": "ETAG123",
            "DistributionConfig": {
                "Origins": {"Items": [
                    {"Id": "origin-ec2", "DomainName": "old.sslip.io"},
                    {"Id": "origin-apigw", "DomainName": "api.example.com"},
                ]}
            },
        }

        with patch("boto3.client", return_value=mock_cf):
            result = handler.update_cloudfront("1.2.3.4")

        assert result["status"] == "ok"
        assert result["domain"] == "1-2-3-4.sslip.io"
        mock_cf.update_distribution.assert_called_once()

    def test_cloudfront_mode_skips_when_unchanged(self, monkeypatch):
        monkeypatch.setenv("INSTANCE_ID", "i-test123")
        monkeypatch.setenv("MODE", "cloudfront")
        monkeypatch.setenv("DISTRIBUTION_IDS", "EXXXTEST")
        monkeypatch.setenv("ORIGIN_ID", "origin-ec2")

        import sys
        sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "lambda", "dns-updater"))

        for key in list(sys.modules.keys()):
            if "handler" in key:
                del sys.modules[key]

        import handler
        import importlib
        importlib.reload(handler)

        handler.ec2 = MagicMock()

        mock_cf = MagicMock()
        mock_cf.get_distribution_config.return_value = {
            "ETag": "ETAG123",
            "DistributionConfig": {
                "Origins": {"Items": [
                    {"Id": "origin-ec2", "DomainName": "1-2-3-4.sslip.io"},
                ]}
            },
        }

        with patch("boto3.client", return_value=mock_cf):
            result = handler.update_cloudfront("1.2.3.4")

        assert result["status"] == "ok"
        assert result["results"][0]["status"] == "unchanged"
        mock_cf.update_distribution.assert_not_called()
