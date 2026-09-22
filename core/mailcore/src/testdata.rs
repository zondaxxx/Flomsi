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
iVBORw0KGgo=\r
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

pub const PNG_SIGNATURE: &[u8] = b"\x89PNG\r\n\x1a\n";
pub const PDF_BYTES: &[u8] = b"%PDF-1.4\n";
