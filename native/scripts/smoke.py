#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Opt-in local integration check: at most one PDF and one PS to bandeja_pdf.

Run with Python and the requirements-dev.txt dependencies, after installing the
native app and choosing an idle interval:

  python3 native/scripts/smoke.py --submit --require-ps

Only the exact queue bandeja_pdf at loopback:18633/ipp/print is accepted.
No setup, queue mutation, UI control, delete, clear, cancellation or auto-retry of
submission is performed. Created document IDs are reported for selective cleanup.
Submission requires the explicit --submit flag.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.parse import urlsplit
import uuid


QUEUE = "bandeja_pdf"
PORT = 18633
NATIVE = Path(__file__).resolve().parents[1]
DEFAULT_CLI = Path.home() / "Applications/Bandeja PDF.app/Contents/Helpers/BandejaCLI"
TOKENS = ["000123", "01/11/2026", "1234,56", "acción", "niño", "pingüino", "ÁÉÍÓÚ"]
TEXT_LINES = [
    "DUA 000123 | Fecha 01/11/2026 | Importe 1234,56",
    "Acentos: acción, niño, pingüino, ÁÉÍÓÚ",
    "DATOS SINTÉTICOS - Prueba de Bandeja PDF",
]


class SmokeFailure(RuntimeError):
    pass


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run_command(arguments, *, input_data=None, timeout=20):
    env = dict(os.environ)
    env.update({"LC_ALL": "C", "LANG": "C", "CUPS_SERVER": "/private/var/run/cupsd"})
    for key in ("LPDEST", "PRINTER", "CUPS_USER", "IPP_JOB_ID", "BPDF_RECEIVER_SESSION"):
        env.pop(key, None)
    try:
        result = subprocess.run([str(arg) for arg in arguments], input=input_data,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=timeout, env=env)
    except subprocess.TimeoutExpired as error:
        raise SmokeFailure(
            "Tiempo agotado; el resultado puede estar pendiente. No repetir el envío automáticamente. "
            + str(arguments[0])) from error
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        if not detail:
            detail = result.stdout.decode("utf-8", errors="replace").strip()
        raise SmokeFailure("Falló %s: %s" % (arguments[0], detail[:2000]))
    return result.stdout.decode("utf-8", errors="strict")


def request(cli, operation, *, timeout=30, **fields):
    # Full defaults also work with an older synthesized AgentRequest decoder.
    payload = {"operation": operation, "documentIDs": [], "pageIndices": [],
               "degrees": 90, "includeWaiting": False, **fields}
    raw = run_command([cli, "request"], input_data=json.dumps(payload).encode(), timeout=timeout)
    try:
        response = json.loads(raw)
    except ValueError as error:
        raise SmokeFailure("BandejaCLI devolvió una respuesta que no es JSON") from error
    if response.get("ok") is not True:
        raise SmokeFailure(response.get("message", "El agente no confirmó la operación"))
    return response


def snapshot(cli):
    value = request(cli, "snapshot").get("snapshot")
    if not isinstance(value, dict) or not isinstance(value.get("inbox"), list) or not isinstance(value.get("waiting"), list):
        raise SmokeFailure("El agente no devolvió una bandeja válida")
    return value


def documents(state):
    return state["inbox"] + state["waiting"]


def summary(state):
    return {"inbox_count": len(state["inbox"]), "waiting_count": len(state["waiting"]),
            "discarded": state.get("discarded", 0), "noticePending": state.get("noticePending", False),
            "noticeVersion": state.get("noticeVersion", 0), "revision": state.get("revision", 0),
            "receiverStatus": state.get("receiverStatus")}


def require_capacity(state, number_of_jobs):
    # Never exercise saturation or use waiting storage for this integration smoke.
    # Keep at least one principal-tray slot free even after both synthetic jobs.
    if state["waiting"] or len(state["inbox"]) + number_of_jobs > 9:
        raise SmokeFailure("No hay margen suficiente para probar sin llenar bandejas; no se envía otro trabajo")


def check_queue():
    value = run_command(["/usr/bin/lpstat", "-v", QUEUE])
    match = re.search(r"\bipps?://\S+", value)
    if not match:
        raise SmokeFailure("La cola esperada no tiene un destino IPP verificable")
    target = urlsplit(match.group(0))
    if (target.hostname not in ("localhost", "127.0.0.1", "::1") or target.port != PORT
            or target.path != "/ipp/print" or target.username is not None):
        raise SmokeFailure("La cola bandeja_pdf no apunta al receptor local esperado; no se envía nada")
    accepted = run_command(["/usr/bin/lpstat", "-a", QUEUE])
    status = run_command(["/usr/bin/lpstat", "-p", QUEUE])
    if ("not accepting requests" in accepted.casefold() or "no acepta peticiones" in accepted.casefold()
            or "disabled" in status.casefold() or "desactivada" in status.casefold()):
        raise SmokeFailure("La cola nueva no está disponible; el smoke no la activa ni la reconfigura")
    return {"queue": QUEUE, "device_uri": match.group(0), "accepting": accepted.strip(), "status": status.strip()}


def make_pdf(path, marker):
    from reportlab.pdfgen import canvas
    pdf = canvas.Canvas(str(path), pagesize=(595, 842), invariant=True)
    pdf.setTitle(marker)
    pdf.setFont("Helvetica", 12)
    for i, line in enumerate([marker, *TEXT_LINES]):
        pdf.drawString(36, 792 - i * 24, line)
    pdf.rect(30, 695, 535, 120)
    pdf.showPage()
    pdf.save()


def ps_string(value):
    result = []
    for byte in value.encode("latin-1"):
        if byte in (40, 41, 92):
            result.append("\\" + chr(byte))
        elif 32 <= byte < 127:
            result.append(chr(byte))
        else:
            result.append("\\%03o" % byte)
    return "(" + "".join(result) + ")"


def make_ps(path, marker):
    lines = [
        "%!PS-Adobe-3.0", "%%Title: " + marker, "%%Pages: 1", "%%EndComments",
        "/Helvetica-Latin1 /Helvetica findfont dup length dict begin",
        "{1 index /FID ne {def} {pop pop} ifelse} forall",
        "/Encoding ISOLatin1Encoding dup length array copy def",
        "Encoding 45 /hyphen put currentdict end definefont pop",
        "%%Page: 1 1", "<< /PageSize [595 842] >> setpagedevice",
        "/Helvetica-Latin1 findfont 12 scalefont setfont",
    ]
    for i, line in enumerate([marker, *TEXT_LINES]):
        lines.append("36 %d moveto %s show" % (792 - i * 24, ps_string(line)))
    lines.extend(["newpath 30 695 moveto 535 0 rlineto 0 120 rlineto -535 0 rlineto closepath stroke",
                  "showpage", "%%EOF", ""])
    path.write_text("\n".join(lines), encoding="ascii")


def pdf_evidence(path, marker):
    from pypdf import PdfReader
    reader = PdfReader(path)
    text = "\n".join(page.extract_text() or "" for page in reader.pages)
    expected = [marker, *TOKENS]
    sizes = [[float(page.mediabox.width), float(page.mediabox.height)] for page in reader.pages]
    return {"pages": len(reader.pages), "text_characters": len(text), "sizes": sizes,
            "expected_tokens": {token: token in text for token in expected},
            "sha256": sha256(path),
            "passed": len(reader.pages) == 1 and all(token in text for token in expected)
                      and all(abs(sizes[0][i] - value) < 0.02 for i, value in enumerate([595, 842]))}


def await_document(cli, marker, baseline_ids, timeout):
    deadline = time.monotonic() + timeout
    while True:
        state = snapshot(cli)
        matches = [document for document in documents(state)
                   if marker in document.get("title", "") and document.get("id") not in baseline_ids]
        if len(matches) > 1:
            raise SmokeFailure("Apareció más de un documento con el identificador sintético; revisar duplicados")
        if matches:
            return matches[0], state
        if time.monotonic() >= deadline:
            raise SmokeFailure("No se confirmó el ingreso del documento; consultar la cola y no repetir a ciegas")
        time.sleep(0.5)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--submit", action="store_true", help="Enviar como máximo dos trabajos sintéticos a la cola nueva")
    parser.add_argument("--cli", type=Path, default=DEFAULT_CLI)
    parser.add_argument("--ghostscript", type=Path, help="Runtime GS privado; por defecto se busca dentro de la app del CLI")
    parser.add_argument("--require-ps", action="store_true", help="Fallar antes de enviar si no se puede comprobar GS")
    parser.add_argument("--timeout", type=float, default=60, help="Espera máxima de ingreso por documento, en segundos")
    args = parser.parse_args()
    if not args.submit:
        parser.error("No se envía nada sin --submit. Este script no instala ni configura la app.")
    if not (1 <= args.timeout <= 180):
        parser.error("--timeout debe estar entre 1 y 180 segundos")
    cli = args.cli.expanduser().resolve()
    if not cli.is_file() or not os.access(cli, os.X_OK):
        parser.error("BandejaCLI no está disponible en la ruta indicada")

    run_id = str(uuid.uuid4())
    run_dir = NATIVE / "build" / "smoke" / run_id
    run_dir.mkdir(parents=True, mode=0o700)
    report_path = run_dir / "result.json"
    report = {"run_id": run_id, "status": "running", "scope": "one PDF and optional one PS; exact new queue only",
              "queue": QUEUE, "cli": str(cli), "jobs": [], "cleanup_document_ids": [],
              "cleanup_performed": False, "report": str(report_path)}

    def save():
        temporary = run_dir / "result.json.tmp"
        temporary.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(report_path)

    save()
    try:
        gs = args.ghostscript.expanduser().resolve() if args.ghostscript else cli.parent.parent / "Resources/ghostscript/bin/gs"
        cases = ["pdf"]
        if gs.is_file() and os.access(gs, os.X_OK):
            report["ghostscript"] = {"path": str(gs), "version": run_command([gs, "--version"]).strip()}
            cases.append("ps")
        elif args.require_ps:
            raise SmokeFailure("No se encontró el runtime privado de Ghostscript; no se envió ningún trabajo")
        else:
            report["postscript"] = "skipped: Ghostscript was not found; this run only validates PDF"
        report["preflight"] = check_queue()
        before = snapshot(cli)
        baseline = {doc["id"]: doc for doc in documents(before)}
        require_capacity(before, len(cases))
        report["before"] = summary(before)
        save()

        for index, kind in enumerate(cases):
            current = snapshot(cli)
            known = set(baseline) | set(report["cleanup_document_ids"])
            if any(doc["id"] not in known for doc in documents(current)):
                raise SmokeFailure("Hay actividad concurrente ajena a la prueba; se detienen nuevos envíos")
            require_capacity(current, len(cases) - index)
            check_queue()
            marker = "BDP-smoke-" + kind + "-" + run_id
            source = run_dir / (marker + "." + kind)
            (make_pdf if kind == "pdf" else make_ps)(source, marker)
            record = {"kind": kind, "marker": marker, "source": str(source), "source_sha256": sha256(source),
                      "submission_attempted": False, "document_id": None}
            report["jobs"].append(record)
            # Persist the intent first; a killed client cannot imply the job was rejected.
            record["submission_attempted"] = True
            save()
            print("Enviando solo a %s: %s" % (QUEUE, marker), flush=True)
            output = run_command(["/usr/bin/lp", "-d", QUEUE, "-t", marker, source])
            record["lp_response"] = output.strip()
            job = re.search(r"\b" + re.escape(QUEUE) + r"-(\d+)\b", output)
            record["cups_job_id"] = int(job.group(1)) if job else None
            save()
            document, received = await_document(cli, marker, set(baseline), args.timeout)
            record["document_id"] = document["id"]
            report["cleanup_document_ids"].append(document["id"])
            record["text_status"] = document.get("textStatus")
            save()
            exported = run_dir / (marker + "-export.pdf")
            response = request(cli, "export", timeout=120, documentIDs=[document["id"]], path=str(exported))
            if response.get("path") and Path(response["path"]).resolve() != exported.resolve():
                raise SmokeFailure("El exportador devolvió otra ruta; no se valida un archivo ajeno")
            if not exported.is_file():
                raise SmokeFailure("La exportación no produjo el archivo solicitado")
            record["export"] = pdf_evidence(exported, marker)
            record["source_unchanged"] = sha256(source) == record["source_sha256"]
            record["unchanged_pdf_hash_matches"] = (sha256(exported) == record["source_sha256"]) if kind == "pdf" else None
            record["passed"] = (record["export"]["passed"] and record["source_unchanged"]
                                and document.get("textStatus") == "text"
                                and (kind != "pdf" or record["unchanged_pdf_hash_matches"]))
            save()
            if not record["passed"]:
                raise SmokeFailure("Falló una comprobación de texto, geometría o copia intacta; ver result.json")
            print("Verificado: %s; documento %s" % (kind.upper(), document["id"]), flush=True)

        after = snapshot(cli)
        after_map = {doc["id"]: doc for doc in documents(after)}
        report["after"] = summary(after)
        report["existing_documents_unchanged"] = all(after_map.get(key) == value for key, value in baseline.items())
        report["discard_count_unchanged"] = after.get("discarded", 0) == before.get("discarded", 0)
        report["notice_state_unchanged"] = (after.get("noticePending"), after.get("noticeVersion")) == (before.get("noticePending"), before.get("noticeVersion"))
        expected_ids = set(baseline) | set(report["cleanup_document_ids"])
        report["no_unexpected_documents"] = set(after_map) == expected_ids
        if not all(report[key] for key in ("existing_documents_unchanged", "discard_count_unchanged",
                                           "notice_state_unchanged", "no_unexpected_documents")):
            raise SmokeFailure("La bandeja tuvo otros cambios durante la prueba; revisar antes de atribuirlos al smoke")
        report["status"] = "passed_pdf_and_ps" if "ps" in cases else "passed_pdf_only"
    except Exception as error:
        report["status"] = "failed_or_unconfirmed"
        report["error"] = str(error)
    finally:
        save()
        print(json.dumps({"status": report["status"], "report": str(report_path),
                          "cleanup_document_ids": report["cleanup_document_ids"],
                          "cleanup_performed": False, "error": report.get("error")}, ensure_ascii=False, indent=2), flush=True)
    return 0 if report["status"].startswith("passed_") else 1


if __name__ == "__main__":
    sys.exit(main())
