//! Fixtures shared by unit tests.

/// multipart/mixed: an HTML body with an inline PNG (multipart/related, `cid:logo@studio.dev`)
/// and a PDF attachment whose name is RFC 2231-encoded Cyrillic ("Счёт.pdf").
pub const INVOICE_EML: &[u8] = b"From: Anna Sokolova <anna@studio.dev>\r
To: z@x.dev\r
Subject: Invoice for September\r
Message-ID: <inv@studio.dev>\r
Date: Tue, 22 Sep 2026 09:12:00 +0300\r
MIME-Version: 1.0\r
Content-Type: multipart/mixed; boundary=\"MIX\"\r
\r
--MIX\r
Content-Type: multipart/related; boundary=\"REL\"\r
\r
--REL\r
Content-Type: text/html; charset=utf-8\r
\r
<p>See attached.</p><img src=\"cid:logo@studio.dev\" alt=\"logo\">\r
--REL\r
Content-Type: image/png\r
Content-ID: <logo@studio.dev>\r
Content-Transfer-Encoding: base64\r
\r
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==\r
--REL--\r
\r
--MIX\r
Content-Type: application/pdf\r
Content-Disposition: attachment; filename*=utf-8''%D0%A1%D1%87%D1%91%D1%82.pdf\r
Content-Transfer-Encoding: base64\r
\r
JVBERi0xLjQK\r
--MIX--\r
";

/// The inline image of INVOICE_EML: a real 1×1 PNG (the sanitizer reads its size).
pub const PNG_SIGNATURE: &[u8] = b"\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\x0d\x49\x44\x41\x54\x78\xda\x63\x64\x60\xf8\x5f\x0f\x00\x02\x87\x01\x80\xeb\x47\xba\x92\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";
pub const PDF_BYTES: &[u8] = b"%PDF-1.4\n";
