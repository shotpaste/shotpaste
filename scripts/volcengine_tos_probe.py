#!/usr/bin/env python3
"""Development-only private TOS staging probe. Requires tos==2.9.2.

Only uploads the official public short sample. Does not read user recordings.
Creates one dedicated private bucket, never takes over or deletes existing buckets.
Credentials and signed URLs are never serialized in reports.
"""
import argparse
import getpass
import hashlib
import json
import logging
import re
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from volcengine_transcription_probe import ASRProbe, NoRedirect, ProbeFailure, SAMPLE, credential, persist


def validate_resources(resources):
    installation = resources.get("installation", "")
    if (not re.fullmatch(r"[a-f0-9]{12}", installation) or
            resources.get("region") != "cn-beijing" or
            resources.get("bucket") != "shotpaste-tmp-poc-" + installation + "-debug" or
            resources.get("prefix") != "transcription/v1/" + installation + "/"):
        raise ProbeFailure("invalid_poc_resources")


def get_public(url, maximum=2_000_000):
    opener = urllib.request.build_opener(NoRedirect)
    try:
        try:
            response = opener.open(url, timeout=30)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            status = response.status
            data = response.read(maximum + 1)
        if len(data) > maximum:
            raise ProbeFailure("response_limit")
        return status, data
    except ProbeFailure:
        raise
    except Exception:
        raise ProbeFailure("transport_failed") from None


def safe_sdk_error(error):
    # SDK exceptions may embed the full request URL; never stringify them.
    code = getattr(error, "code", "")
    allowed = {"AccessDenied", "NoSuchKey", "NoSuchBucket", "BucketAlreadyExists",
               "BucketAlreadyOwnedByYou", "NoSuchLifecycleConfiguration", "InvalidArgument",
               "InvalidAccessKeyId", "SignatureDoesNotMatch", "InvalidBucketName"}
    return {"code": code if code in allowed else "tos_failed",
            "http": getattr(error, "status_code", None) if
            type(getattr(error, "status_code", None)) is int else None}


def verify_deleted(client, bucket, key):
    import tos
    try:
        client.head_object(bucket, key)
    except tos.exceptions.TosServerError as error:
        if error.status_code != 404:
            raise ProbeFailure("deletion_not_verified") from None
        # HEAD has no JSON error body. Confirm the bucket still exists so its
        # own 404 cannot be mistaken for a deleted object.
        client.head_bucket(bucket)
        return
    raise ProbeFailure("object_still_exists")


def validate_report_reference(resources, report):
    if (report.get("bucket") != resources["bucket"] or report.get("prefix") != resources["prefix"]
            or not re.fullmatch(re.escape(resources["prefix"]) + r"[a-f0-9-]{36}/sample\.mp3", report.get("object_key", ""))):
        raise ProbeFailure("unsafe_cleanup_reference")


def cleanup_only(resources, report_path, ak, sk):
    import tos
    validate_resources(resources)
    report_path = Path(report_path)
    report = json.loads(report_path.read_text())
    validate_report_reference(resources, report)
    logging.getLogger("tos").disabled = True
    client = tos.TosClientV2(credential(ak), credential(sk),
                             endpoint="https://tos-cn-beijing.volces.com", region="cn-beijing",
                             max_retry_count=0, follow_redirect_times=0)
    try:
        client.delete_object(resources["bucket"], report["object_key"])
        verify_deleted(client, resources["bucket"], report["object_key"])
        report["cleanup"] = "cleaned"
        report.pop("cleanup_error", None)
    except Exception as error:
        # SDK exceptions can include authentication or a signed request URL.
        # Keep a retryable receipt instead of letting the CLI print a traceback.
        report["cleanup"] = "pending"
        report["cleanup_error"] = safe_sdk_error(error)
    finally:
        client.close()
    persist(report_path, report)
    return report


def run(resources, report_path, ak, sk, speech_key=None, resume_setup=False):
    import tos
    from tos.enum import ACLType, AzRedundancyType, GranteeType, HttpMethodType, StatusType, StorageClassType
    from tos.models2 import BucketLifeCycleRule, BucketLifeCycleExpiration, BucketLifeCycleAbortInCompleteMultipartUpload

    validate_resources(resources)
    logging.getLogger("tos").disabled = True
    client = tos.TosClientV2(credential(ak), credential(sk),
                             endpoint="https://tos-cn-beijing.volces.com", region="cn-beijing",
                             max_retry_count=0, follow_redirect_times=0)
    bucket, prefix = resources["bucket"], resources["prefix"]
    report_path = Path(report_path)
    if resume_setup:
        report = json.loads(report_path.read_text())
        validate_report_reference(resources, report)
        if (report.get("bucket") != bucket or report.get("prefix") != prefix or
                report.get("cleanup") != "not_uploaded" or
                not report.get("checks", {}).get("created_with_restricted_identity")):
            raise ProbeFailure("unsafe_setup_resume")
    else:
        if report_path.exists():
            raise ProbeFailure("existing_report_requires_review")
        report = {"bucket": bucket, "prefix": prefix, "region": "cn-beijing",
                  "object_key": prefix + str(uuid.uuid4()) + "/sample.mp3",
                  "stage": "creating_bucket", "cleanup": "not_uploaded", "checks": {}}
        persist(report_path, report, create_only=True)
    object_may_exist = False
    try:
        if not resume_setup:
            client.create_bucket(bucket, acl=ACLType.ACL_Private,
                                 storage_class=StorageClassType.Storage_Class_Standard,
                                 az_redundancy=AzRedundancyType.Az_Redundancy_Single_Az)
            report["checks"]["created_with_restricted_identity"] = True
            persist(report_path, report)
        report["stage"] = "checking_bucket"
        metadata = client.head_bucket(bucket)
        if metadata.region != "cn-beijing" or metadata.storage_class != StorageClassType.Storage_Class_Standard:
            raise ProbeFailure("unexpected_bucket_properties")
        acl = client.get_bucket_acl(bucket)
        if not acl.owner or any(g.grantee.type != GranteeType.Grantee_User or
                                g.grantee.id != acl.owner.id for g in acl.grants):
            raise ProbeFailure("bucket_not_private")
        # SDK 2.9.2 maps the service's unversioned value to Unknown. Inspect only
        # the raw Status field through a signed, bucket-scoped GET instead.
        version_url = client.pre_signed_url(HttpMethodType.Http_Method_Get, bucket,
                                            query={"versioning": ""}, expires=60).signed_url
        version_http, version_bytes = get_public(version_url)
        version_body = json.loads(version_bytes) if version_http == 200 else None
        version_status = version_body.get("Status") if isinstance(version_body, dict) else "invalid"
        report["versioning_status"] = version_status if version_status in (None, "", "Disabled", "Enabled", "Suspended") else "unknown"
        if version_http != 200 or version_status not in (None, "", "Disabled"):
            raise ProbeFailure("bucket_versioning_not_disabled")
        report["checks"]["private_standard_unversioned"] = True
        report["stage"] = "lifecycle"
        client.put_bucket_lifecycle(bucket, rules=[BucketLifeCycleRule(
            id="shotpaste-temporary-audio", prefix=prefix, status=StatusType.Status_Enable,
            expiration=BucketLifeCycleExpiration(days=2),
            abort_in_complete_multipart_upload=BucketLifeCycleAbortInCompleteMultipartUpload(days_after_init=2))])
        rules = client.get_bucket_lifecycle(bucket).rules
        if (len(rules) != 1 or rules[0].prefix != prefix or
                rules[0].status != StatusType.Status_Enable or rules[0].expiration.days != 2 or
                rules[0].abort_in_complete_multipart_upload.days_after_init != 2):
            raise ProbeFailure("lifecycle_verification_failed")
        report["checks"]["two_day_prefix_lifecycle"] = True
        persist(report_path, report)
        report["stage"] = "download_public_sample"
        status, sample = get_public(SAMPLE)
        if status != 200 or not sample:
            raise ProbeFailure("sample_unavailable")
        checksum = hashlib.sha256(sample).hexdigest()
        report["sample_bytes"] = len(sample)
        report["sample_sha256"] = checksum
        report["stage"] = "uploading"
        report["cleanup"] = "pending"
        persist(report_path, report)
        object_may_exist = True
        client.put_object(bucket, report["object_key"], content=sample,
                          content_type="audio/mpeg", forbid_overwrite=True)
        report["checks"]["upload"] = True
        object_url = "https://" + bucket + ".tos-cn-beijing.volces.com/" + report["object_key"]
        report["stage"] = "private_access"
        anonymous_status, _ = get_public(object_url)
        if anonymous_status != 403:
            raise ProbeFailure("anonymous_access_not_denied")
        report["checks"]["anonymous_get_denied"] = True
        signed = client.pre_signed_url(HttpMethodType.Http_Method_Get, bucket,
                                       key=report["object_key"], expires=86400).signed_url
        parsed = urllib.parse.urlsplit(signed)
        if (parsed.scheme != "https" or parsed.hostname != bucket + ".tos-cn-beijing.volces.com"
                or parsed.path != "/" + report["object_key"]):
            raise ProbeFailure("unexpected_signed_endpoint")
        status, fetched = get_public(signed)
        if status != 200 or hashlib.sha256(fetched).hexdigest() != checksum:
            raise ProbeFailure("signed_download_failed")
        report["checks"]["signed_get_checksum"] = True
        # Read outside the permitted prefix must be denied, even for a missing key.
        report["stage"] = "negative_permission_check"
        try:
            client.head_object(bucket, "outside-prefix-probe")
            raise ProbeFailure("prefix_isolation_failed")
        except tos.exceptions.TosServerError as error:
            if error.status_code != 403:
                raise ProbeFailure("prefix_isolation_not_proven") from None
        report["checks"]["outside_prefix_denied"] = True
        persist(report_path, report)
        if speech_key:
            report["stage"] = "transcribing"
            persist(report_path, report)
            asr_path = report_path.with_name(report_path.stem + "-asr.json")
            asr = ASRProbe(speech_key).run(asr_path, staged_audio_url=signed)
            report["checks"]["asr"] = asr["outcome"] == "passed"
            if not report["checks"]["asr"]:
                raise ProbeFailure("asr_not_complete")
            report["result_ref"] = asr_path.name
        report["outcome"] = "passed" if speech_key else "storage_only_passed"
    except ProbeFailure as error:
        report["outcome"] = str(error)
    except Exception as error:
        report["outcome"] = "tos_failed"
        report["error"] = safe_sdk_error(error)
    finally:
        if object_may_exist:
            try:
                client.delete_object(bucket, report["object_key"])
                verify_deleted(client, bucket, report["object_key"])
                report["cleanup"] = "cleaned"
                report.pop("cleanup_error", None)
            except Exception as error:
                report["cleanup_error"] = safe_sdk_error(error)
        persist(report_path, report)
        client.close()
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--resume-setup", action="store_true", help="Resume only before any upload")
    parser.add_argument("--cleanup-only", action="store_true", help="Delete only the recorded public sample")
    args = parser.parse_args()
    try:
        resources = json.loads(args.resources.read_text())
        validate_resources(resources)
        ak, sk = getpass.getpass("TOS AK: "), getpass.getpass("TOS SK: ")
        if args.cleanup_only:
            report = cleanup_only(resources, args.report, ak, sk)
        else:
            report = run(resources, args.report, ak, sk, getpass.getpass("Speech Key: "), args.resume_setup)
        print(json.dumps({"outcome": report["outcome"], "cleanup": report["cleanup"]}))
        raise SystemExit(0 if report["outcome"] == "passed" and report["cleanup"] == "cleaned" else 1)
    except ProbeFailure as error:
        print(str(error))
        raise SystemExit(1) from None
