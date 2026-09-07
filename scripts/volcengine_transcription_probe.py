#!/usr/bin/env python3
"""Development-only ASR 2.0 probe. Never imported or shipped by either app.

Uses only the official public sample. Credentials remain in process memory.
A persisted request ID prevents silently submitting another billable task after
an interrupted run. This probe does not establish TOS or native-app acceptance.
"""

import argparse
import getpass
import json
import os
import re
import time
import urllib.error
import urllib.request
import urllib.parse
import uuid
from pathlib import Path

ENDPOINT = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/"
RESOURCE = "volc.seedasr.auc"
SAMPLE = (
    "https://lf3-static.bytednsdoc.com/obj/eden-cn/lm_hz_ihsph/"
    "ljhwZthlaukjlkulzlp/console/bigtts/zh_female_cancan_mars_bigtts.mp3"
)
MAX_RESPONSE = 2_000_000
PENDING_CODES = {"20000001", "20000002"}


class ProbeFailure(Exception):
    """Only fixed local codes may escape the HTTP boundary."""


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def credential(value):
    value = value.strip()
    if not value or len(value) > 4096 or any(not 33 <= ord(c) <= 126 for c in value):
        raise ProbeFailure("invalid_credential")
    return value


def safe_code(value):
    return value if isinstance(value, str) and re.fullmatch(r"[0-9]{8}", value) else ""


def safe_log_id(value):
    return value if isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,128}", value) else ""


def task_id(value):
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise ProbeFailure("invalid_task_id") from None


def validate_result(body):
    if not isinstance(body, dict):
        raise ProbeFailure("invalid_result")
    audio = body.get("audio_info")
    result = body.get("result")
    if not isinstance(audio, dict) or not isinstance(result, dict):
        raise ProbeFailure("invalid_result")
    duration = audio.get("duration")
    if type(duration) is not int or not 0 < duration <= 5 * 3600 * 1000:
        raise ProbeFailure("invalid_duration")
    text = result.get("text")
    utterances = result.get("utterances")
    if not isinstance(text, str) or not text.strip():
        raise ProbeFailure("empty_result")
    if not isinstance(utterances, list) or not utterances:
        raise ProbeFailure("missing_utterances")
    cleaned = []
    previous_start = -1
    for utterance in utterances:
        if not isinstance(utterance, dict):
            raise ProbeFailure("invalid_utterance")
        start, end = utterance.get("start_time"), utterance.get("end_time")
        sentence = utterance.get("text")
        if (type(start) is not int or type(end) is not int or
                not 0 <= start < end <= duration or start < previous_start or
                not isinstance(sentence, str) or not sentence.strip()):
            raise ProbeFailure("invalid_utterance")
        additions = utterance.get("additions", {})
        if not isinstance(additions, dict):
            raise ProbeFailure("invalid_utterance")
        speaker = additions.get("speaker")
        if speaker is not None and (not isinstance(speaker, str) or
                                    not re.fullmatch(r"[0-9]{1,8}", speaker)):
            raise ProbeFailure("invalid_speaker")
        cleaned.append({"text": sentence, "start_ms": start, "end_ms": end,
                        "speaker_within_part": speaker})
        previous_start = start
    return {"text": text, "duration_ms": duration, "utterances": cleaned}


def persist(path, report, create_only=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.flush()
        os.fsync(stream.fileno())
    try:
        if create_only:
            # Atomic no-overwrite reservation: two processes cannot both submit.
            try:
                os.link(temporary, path)
            except FileExistsError:
                raise ProbeFailure("existing_report_use_resume") from None
        else:
            os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


class ASRProbe:
    def __init__(self, api_key, opener=None, sleep=time.sleep):
        self.api_key = credential(api_key)
        self.opener = opener or urllib.request.build_opener(NoRedirect)
        self.sleep = sleep

    def call(self, action, identifier, body):
        if action not in {"submit", "query"}:
            raise ProbeFailure("invalid_action")
        request = urllib.request.Request(
            ENDPOINT + action, data=json.dumps(body).encode(), method="POST",
            headers={"Content-Type": "application/json", "X-Api-Key": self.api_key,
                     "X-Api-Resource-Id": RESOURCE, "X-Api-Request-Id": task_id(identifier),
                     "X-Api-Sequence": "-1"})
        try:
            try:
                response = self.opener.open(request, timeout=30)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                metadata = {"action": action, "http": response.status,
                            "code": safe_code(response.headers.get("X-Api-Status-Code")),
                            "log_id": safe_log_id(response.headers.get("X-Tt-Logid"))}
                message = response.headers.get("X-Api-Message", "").lower()
                for phrase, category in (
                    ("requested resource not granted", "resource_not_granted"),
                    ("invalid api key", "invalid_api_key"),
                    ("invalid api-key", "invalid_api_key"),
                    ("quota", "quota"),
                    ("app id", "application_identity"),
                    ("appid", "application_identity"),
                ):
                    if phrase in message:
                        metadata["error_category"] = category
                        break
                raw = response.read(MAX_RESPONSE + 1)
            if len(raw) > MAX_RESPONSE:
                raise ProbeFailure("response_limit")
            # Never persist a server error body or message, even on HTTP 200.
            if metadata["http"] != 200 or metadata["code"] != "20000000":
                return metadata, None
            try:
                body = json.loads(raw)
            except (ValueError, UnicodeError):
                raise ProbeFailure("invalid_json") from None
            if not isinstance(body, dict):
                raise ProbeFailure("invalid_json")
            return metadata, body
        except ProbeFailure:
            raise
        except Exception:
            raise ProbeFailure("transport_failed") from None

    def run(self, path, resume=False, staged_audio_url=None):
        if staged_audio_url is not None:
            parsed = urllib.parse.urlsplit(staged_audio_url)
            if (parsed.scheme != "https" or parsed.port is not None or parsed.username is not None or
                    parsed.password is not None or parsed.fragment or not re.fullmatch(
                        r"shotpaste-tmp-[a-z0-9-]+\.tos-cn-beijing\.volces\.com", parsed.hostname or "") or
                    not parsed.path.startswith("/transcription/v1/")):
                raise ProbeFailure("invalid_staged_endpoint")
        path = Path(path)
        if resume:
            report = json.loads(path.read_text())
            task_id(report["request_id"])
            if report.get("outcome") == "passed":
                return report
        else:
            if path.exists():
                raise ProbeFailure("existing_report_use_resume")
            report = {"resource": RESOURCE, "sample": "tos-public-mp3" if staged_audio_url else "official-public-mp3",
                      "request_id": str(uuid.uuid4()), "task_id": None,
                      "outcome": "submitting", "events": []}
            # Persist BEFORE the only billable submit. Resume never resubmits.
            persist(path, report, create_only=True)
        started = time.monotonic()
        try:
            if not resume:
                metadata, body = self.call("submit", report["request_id"], {
                    "audio": {"url": staged_audio_url or SAMPLE, "format": "mp3"},
                    "request": {"model_name": "bigmodel", "show_utterances": True,
                                "enable_auto_lang": True}})
                report["events"].append(metadata)
                if metadata["http"] != 200 or metadata["code"] != "20000000":
                    raise ProbeFailure("submit_rejected_or_uncertain")
                # Current docs show task_id, but the live service may return {}.
                # In that case query the already persisted request ID; never submit again.
                returned_id = body.get("task_id")
                report["task_id"] = task_id(returned_id) if returned_id is not None else None
                report["outcome"] = "polling"
                persist(path, report)
            identifier = report.get("task_id") or report["request_id"]
            for attempt in range(24):
                self.sleep(min(5 + attempt, 30))
                metadata, body = self.call("query", identifier, {})
                report["events"].append(metadata)
                persist(path, report)
                if metadata["http"] != 200:
                    raise ProbeFailure("query_rejected_or_uncertain")
                if metadata["code"] == "20000000":
                    report["result"] = validate_result(body)
                    report["outcome"] = "passed"
                    break
                if metadata["code"] not in PENDING_CODES:
                    raise ProbeFailure("query_rejected_or_uncertain")
            else:
                raise ProbeFailure("polling_timeout_resume_only")
        except ProbeFailure as error:
            report["outcome"] = str(error)
        finally:
            report["elapsed_seconds"] = round(time.monotonic() - started, 2)
            persist(path, report)
        return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=Path("build/volcengine-account-verification/asr-v2.json"))
    parser.add_argument("--resume", action="store_true", help="Query only; never resubmit")
    args = parser.parse_args()
    try:
        probe = ASRProbe(getpass.getpass("Speech API Key (not saved): "))
        result = probe.run(args.report, args.resume)
        print(result["outcome"])
        return 0 if result["outcome"] == "passed" else 1
    except ProbeFailure as error:
        print(str(error))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
