"""
Merge the per-order PDFs inside an Amazon order-documents zip into ONE PDF.

The "Printable order summary" download is a zip of individual order PDFs named
like '20260602_Printable Order Summary_<orderid>.pdf'. This combines them, in
date order (filename starts YYYYMMDD), into a single PDF for emailing.

Usage:
    python make_pdf.py <zip_path> [out_pdf_path]
Prints the output PDF path on success; exits non-zero on failure / no PDFs.
"""
import io
import sys
import zipfile
from pathlib import Path

from pypdf import PdfWriter, PdfReader


def zip_to_merged_pdf(zip_path, out_path=None):
    zip_path = Path(zip_path)
    if out_path is None:
        out_path = zip_path.with_suffix(".pdf")
    out_path = Path(out_path)

    with zipfile.ZipFile(zip_path) as z:
        names = sorted(n for n in z.namelist() if n.lower().endswith(".pdf"))
        if not names:
            raise ValueError(f"No PDFs found inside {zip_path.name}")
        writer = PdfWriter()
        for n in names:
            data = z.read(n)
            reader = PdfReader(io.BytesIO(data))
            for pg in reader.pages:
                writer.add_page(pg)
        with open(out_path, "wb") as f:
            writer.write(f)
    return out_path, len(names)


def main():
    if len(sys.argv) < 2:
        print("usage: python make_pdf.py <zip_path> [out_pdf_path]", file=sys.stderr)
        sys.exit(2)
    zip_path = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else None
    try:
        out_path, n = zip_to_merged_pdf(zip_path, out)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
    print(out_path)


if __name__ == "__main__":
    main()
