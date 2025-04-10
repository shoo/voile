/*******************************************************************************
 * Crypto
 * 
 * This module provides cryptographic functions for voile.
 * Supported architecture:
 *   - OpenSSL (Apache License 2.0): Enabled when dependent on Deimos OpenSSL library
 *     - [x] AES256 encrypt/decrypt
 *           OpenSSLAESCBCEncryptEngine,
 *           OpenSSLAES128CBCEncryptEngine, OpenSSLAES192CBCEncryptEngine, OpenSSLAES256CBCEncryptEngine,
 *           OpenSSLAESCBCDecryptEngine,
 *           OpenSSLAES128CBCDecryptEngine, OpenSSLAES192CBCDecryptEngine, OpenSSLAES256CBCDecryptEngine,
 *     - [x] Ed25519 sign/verify
 *           OpenSSLEd25519Engine
 *     - [x] ECDSA sign/verify
 *           OpenSSLECDSAP256Engine, OpenSSLECDSAP256KEngine, OpenSSLECDSAP384Engine, OpenSSLECDSAP521Engine
 *     - [x] RSA 4096 sign/verify/encrypt/decrypt
 *           OpenSSLRSA4096Engine
 *     - [x] ECDH P256 key exchange
 *           OpenSSLECDHP256Engine
 *   - Bcrypt (BSD-1.0): Enabled on Windows
 *     - [x] AES256 encrypt/decrypt
 *           BcryptAESCBCEncryptEngine,
 *           BcryptAES128CBCEncryptEngine, BcryptAES192CBCEncryptEngine, BcryptAES256CBCEncryptEngine,
 *           BcryptAESCBCDecryptEngine,
 *           BcryptAES128CBCDecryptEngine, BcryptAES192CBCDecryptEngine, BcryptAES256CBCDecryptEngine,
 *     - [ ] Ed25519 sign/verify - Not Supported
 *           BcryptEd25519Engine
 *     - [x] ECDSA sign/verify
 *           BcryptECDSAP256Engine, BcryptECDSAP256KEngine, BcryptECDSAP384Engine, BcryptECDSAP521Engine
 *     - [x] RSA 4096 sign/verify/encrypt/decrypt
 *           BcryptRSA4096Engine
 *     - [x] ECDH P256 key exchange
 *           BcryptECDHP256Engine
 *   - OpenSSL Command Line Interface (BSD-1.0): Does not work if the command is not available
 *     - [x] AES256 encrypt/decrypt
 *           OpenSSLCmdAESCBCEncryptEngine,
 *           OpenSSLCmdAES128CBCEncryptEngine, OpenSSLCmdAES192CBCEncryptEngine, OpenSSLCmdAES256CBCEncryptEngine,
 *           OpenSSLCmdAESCBCDecryptEngine,
 *           OpenSSLCmdAES128CBCDecryptEngine, OpenSSLCmdAES192CBCDecryptEngine, OpenSSLCmdAES256CBCDecryptEngine,
 *     - [x] Ed25519 sign/verify
 *           OpenSSLCmdEd25519Engine
 *     - [x] ECDSA sign/verify
 *           OpenSSLCmdECDSAP256Engine, OpenSSLCmdECDSAP256KEngine, OpenSSLCmdECDSAP384Engine, OpenSSLCmdECDSAP521Engine
 *     - [x] RSA 4096 sign/verify/encrypt/decrypt
 *           OpenSSLCmdRSA4096Engine
 *     - [x] ECDH P256 key exchange
 *           OpenSSLCmdECDHP256Engine
 * Engines:
 *   - DefaultAES256EncryptEngine
 *   - DefaultAES256DecryptEngine
 *   - DefaultEd25519Engine
 *   - DefaultECDSAP256Engine
 *   - DefaultRSA4096Engine
 *   - DefaultECDHP256Engine
 * Helpers:
 *   - Encrypter
 *     AES256 (with CommonKey, IV), RSA4096 (with PublicKey)
 *   - Decrypter
 *     AES256, RSA4096 (with PrivateKey)
 *   - Signer (opt: Pre hash)
 *     Ed25519 (with PrivateKey), ECDSA P256 (with PrivateKey), RSA4096 (with PrivateKey)
 *   - Verifier (opt: Pre hash)
 *     Ed25519 (with PublicKey), ECDSA P256 (with PublicKey), RSA4096 (with PublicKey)
 *   - Other
 *     pem2der, der2pem, calcHKDF, calcPBKDF2
 */
module voile.crypto;

import std.exception;
import std.range, std.array;
import std.algorithm: move;
import std.digest.sha: SHA256, SHA512;
import std.string: representation;

//##############################################################################
//##### Common Types
//##############################################################################

/*******************************************************************************
 * DER format binary
 */
alias DERBinary = immutable(ubyte)[];

/*******************************************************************************
 * PEM format string
 */
alias PEMString = string;

/*******************************************************************************
 * Raw binary format
 */
alias BinaryKey(size_t N) = ubyte[N];

/*******************************************************************************
 * Binary data
 */
alias bin_t = immutable(ubyte)[];

//##############################################################################
//##### Common functions
//##############################################################################

/*******************************************************************************
 * PEMからDER形式に変換するヘルパ
 */
DERBinary pem2der(in char[] pem) @safe
{
	import std.base64: Base64;
	import std.string;
	auto pemLines = pem.splitLines();
	while (pemLines.length > 0 && pemLines[0].length == 0)
		pemLines = pemLines[1..$];
	while (pemLines.length > 0 && pemLines[$-1].length == 0)
		pemLines = pemLines[0..$-1];
	enforce(pemLines.length >= 3, "Invalid PEM format.");
	enforce(pemLines[0].startsWith("-----BEGIN"), "Invalid PEM format.");
	enforce(pemLines[0].endsWith("-----"), "Invalid PEM format.");
	enforce(pemLines[$-1].startsWith("-----END"), "Invalid PEM format.");
	enforce(pemLines[$-1].endsWith("-----"), "Invalid PEM format.");
	return ((der) @trusted => der.assumeUnique)(Base64.decode(pemLines[1..$-1].join()));
}

@safe unittest
{
	auto pem = "-----BEGIN CERTIFICATE-----\r\n"
		~ "MIIFIDCCBAigAwIBAgISBH+2klDLUAf0T0IFx6PEWV5uMA0GCSqGSIb3DQEBCwUA\r\n"
		~ "MDMxCzAJBgNVBAYTAlVTMRYwFAYDVQQKEw1MZXQncyBFbmNyeXB0MQwwCgYDVQQD\r\n"
		~ "EwNSMTEwHhcNMjUwMzA4MDczMTQ3WhcNMjUwNjA2MDczMTQ2WjAUMRIwEAYDVQQD\r\n"
		~ "EwlkbGFuZy5vcmcwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC+GlKK\r\n"
		~ "om/1QZM/NvIuOlNfnGbkT644ncHIVPX44uietrtbAxg6/9YBykug6MQQcdQbuTlf\r\n"
		~ "ClmQICqUNno/ATw96WqksHKySI2oLc0daNDV3plr4uZlWK8EMHIfV1Jl58g0V2P7\r\n"
		~ "NPz40ll33RbrjspUqnPuQ9URUzs3hveOElXvrmzLQ648Kqz3nO4krv7bSEml2412\r\n"
		~ "XtAfhDgdZwWjNkNsdfej+C+E0Z2xb2da9uE3XYLYbCOAVkH/yIKPq1iyrs5/zwHD\r\n"
		~ "bwaL5bdz4BtLU0o4FOjQqvo2f9dtfOdIwMxwSiIMJR8tpnKgmmqGUGgyqeb0EFB0\r\n"
		~ "B2ip8K7iLVFgKc5RAgMBAAGjggJLMIICRzAOBgNVHQ8BAf8EBAMCBaAwHQYDVR0l\r\n"
		~ "BBYwFAYIKwYBBQUHAwEGCCsGAQUFBwMCMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYE\r\n"
		~ "FCIirdDDrmId1MOONWqpGykznUi+MB8GA1UdIwQYMBaAFMXPRqTq9MPAemyVxC2w\r\n"
		~ "XpIvJuO5MFcGCCsGAQUFBwEBBEswSTAiBggrBgEFBQcwAYYWaHR0cDovL3IxMS5v\r\n"
		~ "LmxlbmNyLm9yZzAjBggrBgEFBQcwAoYXaHR0cDovL3IxMS5pLmxlbmNyLm9yZy8w\r\n"
		~ "UgYDVR0RBEswSYINYXNtLmRsYW5nLm9yZ4IOYmxvZy5kbGFuZy5vcmeCCWRsYW5n\r\n"
		~ "Lm9yZ4IOcmVwbC5kbGFuZy5vcmeCDXd3dy5kbGFuZy5vcmcwEwYDVR0gBAwwCjAI\r\n"
		~ "BgZngQwBAgEwggEEBgorBgEEAdZ5AgQCBIH1BIHyAPAAdgDM+w9qhXEJZf6Vm1PO\r\n"
		~ "6bJ8IumFXA2XjbapflTA/kwNsAAAAZV04GShAAAEAwBHMEUCIQCgNBsXoOB4txm7\r\n"
		~ "1gu/8m6LAUUPuBrr+K+nn4Sus+UNtAIgbAt2XapXc6vtzGwCMn9QJGUC2INfxV1Q\r\n"
		~ "6hkc7pwEu8UAdgBOdaMnXJoQwzhbbNTfP1LrHfDgjhuNacCx+mSxYpo53wAAAZV0\r\n"
		~ "4GSOAAAEAwBHMEUCIEUEUrep9Thb7tua0OjgECuTxZYtw4jsL8a9AZTA7kssAiEA\r\n"
		~ "wPcDEEXdnlgdISysC3FzR7l9lAcH95to4J8B8+aNZEQwDQYJKoZIhvcNAQELBQAD\r\n"
		~ "ggEBABNJoKJh+CxWB4sTkyz9gHLQCMRpLDJtFBXrJekQuBDkKYXWJpg1Typ6Usoh\r\n"
		~ "lFsQ+KRlRschU084ppiW/Y/75twtE7qNS3vooiRJvFCL4XK60Tgo/+ykDvhFGgwW\r\n"
		~ "MPVQmz1//tts9dSa4HE/OGxZf8ERLR1tuNsucmy1kmNM8Nzse52DhfCTQvSzpdGV\r\n"
		~ "p5fqtSEUpKfAwTeXw4NheeTaYuMrR13B8Fl6BfScA+mY4OegwPp38gkcIyiyF+DS\r\n"
		~ "sTxuVVC6R7dPBFFHKWFYFC/GCECyoOXGyVLYBY5A8YfYwH+kJUCrWARkc4Y2JVaT\r\n"
		~ "gVkzhUe1RwgJH38Bf4PPSTU9DgQ=\r\n"
		~ "-----END CERTIFICATE-----\r\n";
	assert(pem2der(pem) == x""
		~ x"3082052030820408A0030201020212047FB69250CB5007F44F4205C7A3C4595E6E300D06092A864886F70D01010B0500"
		~ x"3033310B300906035504061302555331163014060355040A130D4C6574277320456E6372797074310C300A0603550403"
		~ x"1303523131301E170D3235303330383037333134375A170D3235303630363037333134365A3014311230100603550403"
		~ x"1309646C616E672E6F726730820122300D06092A864886F70D01010105000382010F003082010A0282010100BE1A528A"
		~ x"A26FF541933F36F22E3A535F9C66E44FAE389DC1C854F5F8E2E89EB6BB5B03183AFFD601CA4BA0E8C41071D41BB9395F"
		~ x"0A5990202A94367A3F013C3DE96AA4B072B2488DA82DCD1D68D0D5DE996BE2E66558AF0430721F575265E7C8345763FB"
		~ x"34FCF8D25977DD16EB8ECA54AA73EE43D511533B3786F78E1255EFAE6CCB43AE3C2AACF79CEE24AEFEDB4849A5DB8D76"
		~ x"5ED01F84381D6705A336436C75F7A3F82F84D19DB16F675AF6E1375D82D86C23805641FFC8828FAB58B2AECE7FCF01C3"
		~ x"6F068BE5B773E01B4B534A3814E8D0AAFA367FD76D7CE748C0CC704A220C251F2DA672A09A6A86506832A9E6F4105074"
		~ x"0768A9F0AEE22D516029CE510203010001A382024B30820247300E0603551D0F0101FF0404030205A0301D0603551D25"
		~ x"0416301406082B0601050507030106082B06010505070302300C0603551D130101FF04023000301D0603551D0E041604"
		~ x"142222ADD0C3AE621DD4C38E356AA91B29339D48BE301F0603551D23041830168014C5CF46A4EAF4C3C07A6C95C42DB0"
		~ x"5E922F26E3B9305706082B06010505070101044B3049302206082B060105050730018616687474703A2F2F7231312E6F"
		~ x"2E6C656E63722E6F7267302306082B060105050730028617687474703A2F2F7231312E692E6C656E63722E6F72672F30"
		~ x"520603551D11044B3049820D61736D2E646C616E672E6F7267820E626C6F672E646C616E672E6F72678209646C616E67"
		~ x"2E6F7267820E7265706C2E646C616E672E6F7267820D7777772E646C616E672E6F726730130603551D20040C300A3008"
		~ x"060667810C01020130820104060A2B06010401D6790204020481F50481F200F0007600CCFB0F6A85710965FE959B53CE"
		~ x"E9B27C22E9855C0D978DB6A97E54C0FE4C0DB00000019574E064A10000040300473045022100A0341B17A0E078B719BB"
		~ x"D60BBFF26E8B01450FB81AEBF8AFA79F84AEB3E50DB402206C0B765DAA5773ABEDCC6C02327F50246502D8835FC55D50"
		~ x"EA191CEE9C04BBC50076004E75A3275C9A10C3385B6CD4DF3F52EB1DF0E08E1B8D69C0B1FA64B1629A39DF0000019574"
		~ x"E0648E00000403004730450220450452B7A9F5385BEEDB9AD0E8E0102B93C5962DC388EC2FC6BD0194C0EE4B2C022100"
		~ x"C0F7031045DD9E581D212CAC0B717347B97D940707F79B68E09F01F3E68D6444300D06092A864886F70D01010B050003"
		~ x"820101001349A0A261F82C56078B13932CFD8072D008C4692C326D1415EB25E910B810E42985D62698354F2A7A52CA21"
		~ x"945B10F8A46546C721534F38A69896FD8FFBE6DC2D13BA8D4B7BE8A22449BC508BE172BAD13828FFECA40EF8451A0C16"
		~ x"30F5509B3D7FFEDB6CF5D49AE0713F386C597FC1112D1D6DB8DB2E726CB592634CF0DCEC7B9D8385F09342F4B3A5D195"
		~ x"A797EAB52114A4A7C0C13797C3836179E4DA62E32B475DC1F0597A05F49C03E998E0E7A0C0FA77F2091C2328B217E0D2"
		~ x"B13C6E5550BA47B74F045147296158142FC60840B2A0E5C6C952D8058E40F187D8C07FA42540AB580464738636255693"
		~ x"8159338547B54708091F7F017F83CF49353D0E04");
}

/*******************************************************************************
 * PEMからDER形式に変換するヘルパ
 */
PEMString der2pem(in ubyte[] der, string name) @safe
{
	import std.algorithm: map;
	import std.base64: Base64;
	return ("-----BEGIN " ~ name ~ "-----\r\n"
		~ Base64.encode(der).representation.chunks(64).map!((e) @trusted => cast(string)e).join("\r\n")
		~ "\r\n-----END " ~ name ~ "-----\r\n");
}
@safe unittest
{
	auto der = x""
		~ x"3082052030820408A0030201020212047FB69250CB5007F44F4205C7A3C4595E6E300D06092A864886F70D01010B0500"
		~ x"3033310B300906035504061302555331163014060355040A130D4C6574277320456E6372797074310C300A0603550403"
		~ x"1303523131301E170D3235303330383037333134375A170D3235303630363037333134365A3014311230100603550403"
		~ x"1309646C616E672E6F726730820122300D06092A864886F70D01010105000382010F003082010A0282010100BE1A528A"
		~ x"A26FF541933F36F22E3A535F9C66E44FAE389DC1C854F5F8E2E89EB6BB5B03183AFFD601CA4BA0E8C41071D41BB9395F"
		~ x"0A5990202A94367A3F013C3DE96AA4B072B2488DA82DCD1D68D0D5DE996BE2E66558AF0430721F575265E7C8345763FB"
		~ x"34FCF8D25977DD16EB8ECA54AA73EE43D511533B3786F78E1255EFAE6CCB43AE3C2AACF79CEE24AEFEDB4849A5DB8D76"
		~ x"5ED01F84381D6705A336436C75F7A3F82F84D19DB16F675AF6E1375D82D86C23805641FFC8828FAB58B2AECE7FCF01C3"
		~ x"6F068BE5B773E01B4B534A3814E8D0AAFA367FD76D7CE748C0CC704A220C251F2DA672A09A6A86506832A9E6F4105074"
		~ x"0768A9F0AEE22D516029CE510203010001A382024B30820247300E0603551D0F0101FF0404030205A0301D0603551D25"
		~ x"0416301406082B0601050507030106082B06010505070302300C0603551D130101FF04023000301D0603551D0E041604"
		~ x"142222ADD0C3AE621DD4C38E356AA91B29339D48BE301F0603551D23041830168014C5CF46A4EAF4C3C07A6C95C42DB0"
		~ x"5E922F26E3B9305706082B06010505070101044B3049302206082B060105050730018616687474703A2F2F7231312E6F"
		~ x"2E6C656E63722E6F7267302306082B060105050730028617687474703A2F2F7231312E692E6C656E63722E6F72672F30"
		~ x"520603551D11044B3049820D61736D2E646C616E672E6F7267820E626C6F672E646C616E672E6F72678209646C616E67"
		~ x"2E6F7267820E7265706C2E646C616E672E6F7267820D7777772E646C616E672E6F726730130603551D20040C300A3008"
		~ x"060667810C01020130820104060A2B06010401D6790204020481F50481F200F0007600CCFB0F6A85710965FE959B53CE"
		~ x"E9B27C22E9855C0D978DB6A97E54C0FE4C0DB00000019574E064A10000040300473045022100A0341B17A0E078B719BB"
		~ x"D60BBFF26E8B01450FB81AEBF8AFA79F84AEB3E50DB402206C0B765DAA5773ABEDCC6C02327F50246502D8835FC55D50"
		~ x"EA191CEE9C04BBC50076004E75A3275C9A10C3385B6CD4DF3F52EB1DF0E08E1B8D69C0B1FA64B1629A39DF0000019574"
		~ x"E0648E00000403004730450220450452B7A9F5385BEEDB9AD0E8E0102B93C5962DC388EC2FC6BD0194C0EE4B2C022100"
		~ x"C0F7031045DD9E581D212CAC0B717347B97D940707F79B68E09F01F3E68D6444300D06092A864886F70D01010B050003"
		~ x"820101001349A0A261F82C56078B13932CFD8072D008C4692C326D1415EB25E910B810E42985D62698354F2A7A52CA21"
		~ x"945B10F8A46546C721534F38A69896FD8FFBE6DC2D13BA8D4B7BE8A22449BC508BE172BAD13828FFECA40EF8451A0C16"
		~ x"30F5509B3D7FFEDB6CF5D49AE0713F386C597FC1112D1D6DB8DB2E726CB592634CF0DCEC7B9D8385F09342F4B3A5D195"
		~ x"A797EAB52114A4A7C0C13797C3836179E4DA62E32B475DC1F0597A05F49C03E998E0E7A0C0FA77F2091C2328B217E0D2"
		~ x"B13C6E5550BA47B74F045147296158142FC60840B2A0E5C6C952D8058E40F187D8C07FA42540AB580464738636255693"
		~ x"8159338547B54708091F7F017F83CF49353D0E04";
	assert(der2pem(der.representation, "CERTIFICATE") == "-----BEGIN CERTIFICATE-----\r\n"
		~ "MIIFIDCCBAigAwIBAgISBH+2klDLUAf0T0IFx6PEWV5uMA0GCSqGSIb3DQEBCwUA\r\n"
		~ "MDMxCzAJBgNVBAYTAlVTMRYwFAYDVQQKEw1MZXQncyBFbmNyeXB0MQwwCgYDVQQD\r\n"
		~ "EwNSMTEwHhcNMjUwMzA4MDczMTQ3WhcNMjUwNjA2MDczMTQ2WjAUMRIwEAYDVQQD\r\n"
		~ "EwlkbGFuZy5vcmcwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC+GlKK\r\n"
		~ "om/1QZM/NvIuOlNfnGbkT644ncHIVPX44uietrtbAxg6/9YBykug6MQQcdQbuTlf\r\n"
		~ "ClmQICqUNno/ATw96WqksHKySI2oLc0daNDV3plr4uZlWK8EMHIfV1Jl58g0V2P7\r\n"
		~ "NPz40ll33RbrjspUqnPuQ9URUzs3hveOElXvrmzLQ648Kqz3nO4krv7bSEml2412\r\n"
		~ "XtAfhDgdZwWjNkNsdfej+C+E0Z2xb2da9uE3XYLYbCOAVkH/yIKPq1iyrs5/zwHD\r\n"
		~ "bwaL5bdz4BtLU0o4FOjQqvo2f9dtfOdIwMxwSiIMJR8tpnKgmmqGUGgyqeb0EFB0\r\n"
		~ "B2ip8K7iLVFgKc5RAgMBAAGjggJLMIICRzAOBgNVHQ8BAf8EBAMCBaAwHQYDVR0l\r\n"
		~ "BBYwFAYIKwYBBQUHAwEGCCsGAQUFBwMCMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYE\r\n"
		~ "FCIirdDDrmId1MOONWqpGykznUi+MB8GA1UdIwQYMBaAFMXPRqTq9MPAemyVxC2w\r\n"
		~ "XpIvJuO5MFcGCCsGAQUFBwEBBEswSTAiBggrBgEFBQcwAYYWaHR0cDovL3IxMS5v\r\n"
		~ "LmxlbmNyLm9yZzAjBggrBgEFBQcwAoYXaHR0cDovL3IxMS5pLmxlbmNyLm9yZy8w\r\n"
		~ "UgYDVR0RBEswSYINYXNtLmRsYW5nLm9yZ4IOYmxvZy5kbGFuZy5vcmeCCWRsYW5n\r\n"
		~ "Lm9yZ4IOcmVwbC5kbGFuZy5vcmeCDXd3dy5kbGFuZy5vcmcwEwYDVR0gBAwwCjAI\r\n"
		~ "BgZngQwBAgEwggEEBgorBgEEAdZ5AgQCBIH1BIHyAPAAdgDM+w9qhXEJZf6Vm1PO\r\n"
		~ "6bJ8IumFXA2XjbapflTA/kwNsAAAAZV04GShAAAEAwBHMEUCIQCgNBsXoOB4txm7\r\n"
		~ "1gu/8m6LAUUPuBrr+K+nn4Sus+UNtAIgbAt2XapXc6vtzGwCMn9QJGUC2INfxV1Q\r\n"
		~ "6hkc7pwEu8UAdgBOdaMnXJoQwzhbbNTfP1LrHfDgjhuNacCx+mSxYpo53wAAAZV0\r\n"
		~ "4GSOAAAEAwBHMEUCIEUEUrep9Thb7tua0OjgECuTxZYtw4jsL8a9AZTA7kssAiEA\r\n"
		~ "wPcDEEXdnlgdISysC3FzR7l9lAcH95to4J8B8+aNZEQwDQYJKoZIhvcNAQELBQAD\r\n"
		~ "ggEBABNJoKJh+CxWB4sTkyz9gHLQCMRpLDJtFBXrJekQuBDkKYXWJpg1Typ6Usoh\r\n"
		~ "lFsQ+KRlRschU084ppiW/Y/75twtE7qNS3vooiRJvFCL4XK60Tgo/+ykDvhFGgwW\r\n"
		~ "MPVQmz1//tts9dSa4HE/OGxZf8ERLR1tuNsucmy1kmNM8Nzse52DhfCTQvSzpdGV\r\n"
		~ "p5fqtSEUpKfAwTeXw4NheeTaYuMrR13B8Fl6BfScA+mY4OegwPp38gkcIyiyF+DS\r\n"
		~ "sTxuVVC6R7dPBFFHKWFYFC/GCECyoOXGyVLYBY5A8YfYwH+kJUCrWARkc4Y2JVaT\r\n"
		~ "gVkzhUe1RwgJH38Bf4PPSTU9DgQ=\r\n"
		~ "-----END CERTIFICATE-----\r\n");
}

/*******************************************************************************
 * HKDFを計算するヘルパ
 */
bin_t calcHKDF(DigestEngine = SHA256)(
	in ubyte[] secret, size_t len, in ubyte[] salt = null, string info = null)
{
	import std.digest.hmac;
	auto prk = secret.hmac!DigestEngine(salt);
	ulong cnt = 1;
	auto app = appender!bin_t;
	app.reserve(len);
	auto t = hmac!DigestEngine(prk[]);
	while (app.data.length < len)
	{
		import core.bitop;
		auto numLen = bsr(cnt) / 8 + 1;
		ulong numBE = bswap(cnt);
		auto numBytes = (() @trusted => (cast(ubyte*)&numBE)[ulong.sizeof-numLen..ulong.sizeof])();
		t.put(info.representation);
		t.put(numBytes);
		auto h = t.finish();
		app.put(h[]);
		t.put(h[]);
		cnt++;
	}
	return app.data[0..len];
}

@safe unittest
{
	// openssl kdf -keylen 32 -kdfopt digest:sha256 -kdfopt salt:test -kdfopt info:aes_key
	//                        -kdfopt "key:Hello, World!" HKDF
	enum sampleSalt1 = "test".representation;
	enum sampleSecret1 = "Hello, World!".representation;
	enum sampleInfo1 = "aes_key";
	enum sample1 = x"0AE651F7225F01DE4D7B5EED6F405664710618F9B3FC6F8C13FA161AAE0C6FEE".bin;
	auto result1 = calcHKDF(sampleSecret1, 32, sampleSalt1, sampleInfo1);
	assert(result1 == sample1);
	// openssl kdf -keylen 48 -kdfopt digest:sha256 -kdfopt info:aes_key -kdfopt "key:Hello, World!" HKDF
	enum sampleSecret2 = "Hello, World!".representation;
	enum sampleInfo2 = "aes_key";
	enum sample2 = representation(x"ED6E11E0A8EBE2B138E3B3761CB5506D80C2288034714F0EF3F6"
		~ x"D37A3AA8F4001737FA86655CDE47F09CCAF57F67182C");
	auto result2 = calcHKDF(sampleSecret2, 48, null, sampleInfo2);
	assert(result2 == sample2);
	// openssl kdf -keylen 280 -kdfopt digest:sha256 -kdfopt "key:Hello, World!" HKDF
	enum sampleSecret3 = "Hello, World!".representation;
	enum sample3 = representation(x"657197A35AE37605DC6754D22051FF6F73D126C18AAF421C2BEC80A2A6F0A245"
		~ x"1034804BD5E19F311060E88E41B10EA6EB7F8E01AFA9D052E66C3C5DC9CBCE786D6416BFBDC74F3AC3BC3AF277DC0B437B82"
		~ x"DA3A4DB824518FC33220BB1546D545116F85E4469994EAC39ED95DBDAEB53E8AD219E4E1453281349F41EA5085E7A864543D"
		~ x"D7BB15289D5197F2CFBF3C26462CD805C8D737A04E75E7F1BA876D2F4448B4B0B964D4C2DB393E705679085A7A8323EBA942"
		~ x"773A80FE298764C002DE8DA75DE78912D2B845DD7FA0E0620CF8981C7127FCD13E16379E6256B23EA91907EB9ED905769000"
		~ x"552FA55F4118A4319D7E9998915FB2AD6BCDBF53375F519784AB3A89808AF5A0A7BFD831BD9BFC03D23B4599D1550145");
	auto result3 = calcHKDF(sampleSecret3, 280);
	assert(result3 == sample3);
}

/*******************************************************************************
 * HKDFを計算するヘルパ
 */
bin_t calcPBKDF2(DigestEngine = SHA256)(
	string password, size_t len, size_t iterations, in ubyte[] salt = null)
{
	import std.digest.hmac;
	auto prf = hmac!DigestEngine(password.representation);
	prf.put(salt);
	auto prfs = prf;
	prf.start();
	size_t cnt = 1;
	auto app = appender!bin_t;
	app.reserve(len);
	while (app.data.length < len)
	{
		import core.bitop;
		auto prfs2 = prfs;
		uint numBE = bswap(cast(uint)cnt);
		auto numBytes = (() @trusted => (cast(ubyte*)&numBE)[0..uint.sizeof])();
		prfs2.put(numBytes);
		auto u = prfs2.finish();
		auto t = u;
		foreach (_; 1 .. iterations)
		{
			prf.put(u[]);
			u = prf.finish();
			t[] ^= u[];
		}
		app.put(t[]);
		cnt++;
	}
	return app.data[0..len];
}

@safe unittest
{
	enum samplePass1 = "password";
	enum sampleSalt1 = cast(immutable(ubyte)[])"salt";
	enum sampleIter1 = 2;
	enum sampleResult1 = cast(immutable(ubyte)[])x"AE4D0C95AF6B46D32D0ADFF928F06DD02A303F8EF3C251DFD6E2D85A95474C43";
	auto result1 = calcPBKDF2(samplePass1, sampleResult1.length, sampleIter1, sampleSalt1);
	assert(result1 == sampleResult1);
	
	enum samplePass2 = "password";
	enum sampleSalt2 = cast(immutable(ubyte)[])"salt";
	enum sampleIter2 = 32;
	enum sampleResult2 = cast(immutable(ubyte)[])(x"64C486C55D30D4C5A079B8823B7D7CB37FF0556F537DA8410233BCEC330ED956"
		~ x"EA3B0DBC4C76CD67DBB1A3D5F0921134234E95951D40D527A7416D1E1F5FBC928C646CBEDC315482C3C8C0F9B58BF52938D7"
		~ x"3DDA7A1611499403EBF93E36D49E");
	auto result2 = calcPBKDF2(samplePass2, sampleResult2.length, sampleIter2, sampleSalt2);
	assert(result2 == sampleResult2);
}

private bin_t bin(bin_t x) => x;

version (unittest) debug private void dispBin(in ubyte[] dat) @trusted
{
	import std.stdio;
	writefln("%(%02X%)", dat);
}

private bin_t encasn1(ubyte type, in ubyte[] data, bool padding = false)
{
	auto leLen = (padding && (data[0] & 0x80) != 0) ? data.length + 1 : data.length;
	bin_t header;
	if (leLen < 128)
	{
		header = (padding && (data[0] & 0x80) != 0) != 0
			? cast(bin_t)[type, cast(ubyte)leLen, 0x00]
			: cast(bin_t)[type, cast(ubyte)leLen];
	}
	else
	{
		import core.bitop: bswap;
		auto beLen = bswap(leLen);
		auto lenfield = (cast(immutable(ubyte)*)&beLen)[0..size_t.sizeof];
		assert(lenfield.length == size_t.sizeof);
		while (lenfield[0] == 0)
			lenfield = lenfield[1..$];
		header = cast(bin_t)[type, 0x80 + cast(ubyte)lenfield.length] ~ lenfield;
		if (padding && (data[0] & 0x80) != 0)
			header ~= 0x00;
	}
	return assumeUnique(header ~ data);
}

private bin_t encasn1ostr(in ubyte[] str)
{
	return encasn1(0x04, str, false);
}
private bin_t encasn1str(in ubyte[] str)
{
	return encasn1(0x03, cast(bin_t)[0x00] ~ str, false);
}
private bin_t encasn1seq(in ubyte[] seq)
{
	return encasn1(0x30, seq, false);
}
private bin_t encasn1bn(in ubyte[] bn)
{
	auto bnsrc = bn[];
	while (bnsrc.length > 0 && bnsrc[0] == 0x00)
		bnsrc = bnsrc[1..$];
	return encasn1(0x02, bnsrc, true);
}
private const(ubyte)[] decasn1(ubyte type, ref const(ubyte)[] dat, bool padding = false)
{
	enforce(dat[0] == type, "Invalid ASN.1 format.");
	dat = dat[1..$];
	size_t len;
	if ((dat[0] & 0x80) == 0)
	{
		len = dat[0];
		dat = dat[1..$];
	}
	else
	{
		auto lenfield = dat[1..1 + dat[0] - 0x80];
		dat = dat[1 + dat[0] - 0x80 .. $];
		foreach (i; 0..lenfield.length)
		{
			len <<= 8;
			len |= lenfield[i];
		}
	}
	auto ret = dat[0..len];
	dat = dat[len..$];
	return (padding && ret.length > 1 && ret[0] == 0x00) ? ret[1 .. $] : ret;
}
private const(ubyte)[] decasn1seq(ref const(ubyte)[] dat)
{
	return decasn1(0x30, dat, false);
}
private const(ubyte)[] decasn1ostr(ref const(ubyte)[] dat)
{
	return decasn1(0x04, dat, false);
}
private const(ubyte)[] decasn1str(ref const(ubyte)[] dat)
{
	auto ret = decasn1(0x03, dat, false);
	enforce(ret.length != 0 && ret[0] == 0x00, "Unsuppported ASN.1 format.");
	return ret[1..$];
}
private const(ubyte)[] decasn1bn(ref const(ubyte)[] dat, size_t len = 0)
{
	import std.range;
	auto ret = decasn1(0x02, dat, true);
	if (len == 0)
		return ret;
	enforce(ret.length <= len, "Invalid ASN.1 format.");
	return repeat(ubyte(0x00), len - ret.length).array ~ ret;
}

/*******************************************************************************
 * 一時ディレクトリを作成し寿命終了と同時に削除する
 */
private auto createDisposableDir(string basePath = null, string prefix = "voile-", uint retrycnt = 5) @safe
{
	import std.path, std.file;
	import std.uuid;
	import std.algorithm: move;
	import core.thread: Thread, msecs;
	struct Dir
	{
	@safe:
		string workDir;
		~this()
		{
			if (workDir.length && workDir.exists)
			{
				foreach (i; 0..10)
				{
					try
						rmdirRecurse(workDir);
					catch (Exception e)
					{
						(() @trusted => Thread.sleep(100.msecs))();
						continue;
					}
					break;
				}
			}
		}
		string path(string name)
		{
			return workDir.buildPath(name);
		}
		string write(T)(string name, in T[] data)
		{
			auto p = path(name);
			std.file.write(p, data);
			return p;
		}
		T read(T)(string name)
		{
			return cast(T)std.file.read(path(name), data);
		}
	}
	Dir ret;
	foreach (tryCnt; 0..retrycnt)
	{
		try
		{
			auto id = randomUUID().toString();
			auto parentDir = basePath.length > 0 ? basePath : tempDir;
			auto newpath = parentDir.buildPath(prefix ~ id);
			if (newpath.exists)
				continue;
			ret.workDir = newpath;
			mkdirRecurse(ret.workDir);
			break;
		}
		catch (Exception e)
			(() @trusted => Thread.sleep(100.msecs))();
	}
	ret.workDir.exists.enforce();
	return ret.move();
}

/*******************************************************************************
 * コマンドの有無を判定する
 */
private bool isCommandExisting(string cmd) @safe
{
	import std.process;
	version (Windows)
	{
		return executeShell(`where "` ~ cmd ~ `"`).status == 0;
	}
	else
	{
		return executeShell("which '" ~ cmd ~ "'").status == 0;
	}
}

private struct SemVer
{
	uint major;
	uint minor;
	uint patch;
	string prerelease;
	string buildmetadata;
	
	bool opEquals(const SemVer lhs) const @safe
	{
		return major == lhs.major
			&& minor == lhs.minor
			&& patch == lhs.patch
			&& prerelease == lhs.prerelease
			&& buildmetadata == lhs.buildmetadata;
	}
	
	int opCmp(const SemVer lhs) const @safe
	{
		import std.string: cmp;
		if (opEquals(lhs))
			return 0;
		if (major < lhs.major)
			return -1;
		if (major > lhs.major)
			return 1;
		if (minor < lhs.minor)
			return -1;
		if (minor > lhs.minor)
			return 1;
		if (patch < lhs.patch)
			return -1;
		if (patch > lhs.patch)
			return 1;
		if (prerelease.cmp(lhs.prerelease) < 0)
			return -1;
		if (prerelease.cmp(lhs.prerelease) > 0)
			return 1;
		if (buildmetadata.cmp(lhs.buildmetadata) < 0)
			return -1;
		if (buildmetadata.cmp(lhs.buildmetadata) > 0)
			return 1;
		return 0;
	}
	
	size_t toHash() const @nogc @safe pure nothrow
	{
		size_t hash;
		hashOf(major, hash);
		hashOf(minor, hash);
		hashOf(patch, hash);
		hashOf(prerelease, hash);
		hashOf(buildmetadata, hash);
		return hash;
	}
}
@safe unittest
{
	assert(SemVer(1, 2, 3) < SemVer(3, 2, 4));
	assert(SemVer(1, 3, 3) > SemVer(1, 2, 4));
	assert(SemVer(1, 2, 3) < SemVer(1, 2, 4));
	assert(SemVer(1, 2, 5) > SemVer(1, 2, 4));
	assert(SemVer(1, 2, 4) == SemVer(1, 2, 4));
	assert(SemVer(1, 2, 4, "rc.1") < SemVer(1, 2, 4, "rc.2"));
}

/*******************************************************************************
 * SemVer
 */
private SemVer getSemVer(string verStr) @safe
{
	import std.regex;
	import std.conv;
	import std.string;
	auto rSemVer = regex(r"^(?P<major>0|[1-9]\d*)\.(?P<minor>0|[1-9]\d*)\.(?P<patch>0|[1-9]\d*)"
		~ r"(?:-(?P<prerelease>(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)"
		~ r"(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?"
		~ r"(?:\+(?P<buildmetadata>[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$");
	if (auto mVer = verStr.matchFirst(rSemVer))
	{
		return SemVer(mVer["major"].to!uint,
			mVer["minor"].to!uint,
			mVer["patch"].to!uint,
			mVer["prerelease"],
			mVer["buildmetadata"]);
	}
	auto vers = verStr.split(".");
	enforce(vers.length >= 3);
	return SemVer(vers[0].to!uint.ifThrown(0), vers[1].to!uint.ifThrown(0), vers[2].to!uint.ifThrown(0));
}

@safe unittest
{
	assert(getSemVer("1.2.3") == SemVer(1, 2, 3));
	assert(getSemVer("1.2.3-rc1") == SemVer(1, 2, 3, "rc1"));
	assert(getSemVer("1.2.3-rc1+abcdef") == SemVer(1, 2, 3, "rc1", "abcdef"));
	assert(getSemVer("1.2.3+abcdef") == SemVer(1, 2, 3, "", "abcdef"));
}

private SemVer parseOpenSSLCmdVersionString(string str) @safe
{
	import std.string;
	enforce(str.startsWith("OpenSSL"));
	auto verstr = str[7..$].stripLeft;
	auto verstrEdIdx = verstr.indexOf(" ");
	enforce(verstrEdIdx != -1);
	return verstr[0..verstrEdIdx].getSemVer();
}
@safe unittest
{
	enum sampleStr1 = "OpenSSL 3.0.13 30 Jan 2024 (Library: OpenSSL 3.0.13 30 Jan 2024)\n";
	enum sampleStr2 = "OpenSSL 1.1.1f  31 Mar 2020\n";
	assert(sampleStr1.parseOpenSSLCmdVersionString() == SemVer(3, 0, 13));
	assert(sampleStr2.parseOpenSSLCmdVersionString() == SemVer(1, 1, 0));
}

/*******************************************************************************
 * コマンドの有無を判定する
 */
private SemVer getOpenSSLCmdVerseion(string cmd) @safe
{
	import std.process;
	auto result = execute([cmd, "version"]);
	enforce(result.status == 0);
	return result.output.parseOpenSSLCmdVersionString();
}

/*******************************************************************************
 * ECDSA Curve Types
 */
private enum ECDSAType
{
	/// Curve of secp256r1/NIST P-256
	p256,
	/// Curve of secp256k1
	p256k,
	/// Curve of secp384r1/NIST P-384
	p384,
	/// Curve of secp521r1/NIST P-521
	p521
}

/// OID
private enum bin_t getOid(ECDSAType type) = false ? x"".bin
	: type == ECDSAType.p256  ? x"2A8648CE3D030107".bin     // OID: 1.2.840.10045.3.1.7 (P-256)
	: type == ECDSAType.p256k ? x"2B8104000A".bin           // OID: 1.3.132.0.10 (P-256K)
	: type == ECDSAType.p384  ? x"2B81040022".bin           // OID: 1.3.132.0.34 (P-384)
	: type == ECDSAType.p521  ? x"2B81040023".bin           // OID: 1.3.132.0.35 (P-521)
	: x"2A8648CE3D030107".bin;                              // OID: 1.2.840.10045.3.1.7 (P-256)

version (all)
{
	private enum enableOpenSSLCmdEngines = true;
}
else
{
	private enum enableOpenSSLCmdEngines = false;
}

version (Have_openssl)
{
	version (X86)
	{
		private enum enableOpenSSLEngines = false;
	}
	else
	{
		private enum enableOpenSSLEngines = true;
	}
}
else
{
	private enum enableOpenSSLEngines = false;
}

version (Windows)
{
	private enum enableBcryptEngines = true;
}
else
{
	private enum enableBcryptEngines = false;
}

//##############################################################################
//##### OpenSSL command line Engine
//##############################################################################
static if (enableOpenSSLCmdEngines)
{
	version (Windows)
	{
		private enum defaultOpenSSLCommand = "openssl.exe";
	}
	else
	{
		private enum defaultOpenSSLCommand = "openssl";
	}
	
	private struct OpenSSLCmdAESCBCEncryptEngine
	{
	private:
		import std.typecons: RefCounted, RefCountedAutoInitialize, refCounted;
		import core.thread;
		import core.sync.mutex;
		import std.process;
		struct Instance
		{
			ProcessPipes pipe;
			Appender!(ubyte[]) app;
			Thread thread;
			Mutex mutex;
			size_t inputSize;
			void entryConsumer()
			{
				foreach (ref chunk; pipe.stdout.byChunk(4096))
					synchronized (mutex)
						app.put(chunk);
			}
		}
		RefCounted!(Instance, RefCountedAutoInitialize.no) _instance;
	public:
		/***************************************************************************
		 * Constructor
		 */
		this(in ubyte[] key, in ubyte[] iv, string cmd = defaultOpenSSLCommand)
		{
			import std.format;
			isCommandExisting(cmd).enforce("OpenSSL command line interface cannot find.");
			_instance = refCounted(Instance.init);
			auto encType = key.length == 32 ? "-aes-256-cbc"
				: key.length == 16 ? "-aes-128-cbc"
				: key.length == 24 ? "-aes-192-cbc"
				: "";
			enforce(encType.length > 0, "Unsupported key type.");
			with (_instance.refCountedPayload)
			{
				pipe = pipeProcess([cmd, "enc", encType, "-e", "-in", "-", "-out", "-", "-nopad",
					"-K", format("%(%02X%)", key), "-iv", format("%(%02X%)", iv)]);
				mutex = new Mutex;
				app = appender!(ubyte[]);
				thread = new Thread(&entryConsumer);
				thread.start();
			}
		}
		/***************************************************************************
		 * Update
		 */
		void update(OutputRange)(in ubyte[] data, ref OutputRange dst)
		if (isOutputRange!(OutputRange, ubyte))
		{
			with (_instance.refCountedPayload)
			{
				pipe.stdin.rawWrite(data);
				inputSize += data.length;
				synchronized (mutex)
				{
					if (app.data.length > 0)
					{
						dst.put(app.data);
						app.shrinkTo(0);
					}
				}
			}
		}
		/***************************************************************************
		 * Finalize
		 */
		void finalize(OutputRange)(ref OutputRange dst, bool padding = true)
		if (isOutputRange!(OutputRange, ubyte))
		{
			with (_instance.refCountedPayload)
			{
				if (padding)
				{
					ubyte[16] pad;
					pad[] = 16 - inputSize % 16;
					pipe.stdin.rawWrite(pad[0..pad[0]]);
				}
				pipe.stdin.flush();
				pipe.stdin.close();
				pipe.pid.wait();
				thread.join();
				dst.put(app.data);
				app.clear();
			}
		}
	}
	private alias OpenSSLCmdAES128CBCEncryptEngine = OpenSSLCmdAESCBCEncryptEngine;
	private alias OpenSSLCmdAES192CBCEncryptEngine = OpenSSLCmdAESCBCEncryptEngine;
	private alias OpenSSLCmdAES256CBCEncryptEngine = OpenSSLCmdAESCBCEncryptEngine;
	
	
	private struct OpenSSLCmdAESCBCDecryptEngine
	{
	private:
		import std.typecons: RefCounted, RefCountedAutoInitialize, refCounted;
		import core.thread;
		import core.sync.mutex;
		import std.process;
		struct Instance
		{
			ProcessPipes pipe;
			Appender!(ubyte[]) app;
			Thread thread;
			Mutex mutex;
			void entryConsumer()
			{
				foreach (ref chunk; pipe.stdout.byChunk(4096))
					synchronized (mutex)
						app.put(chunk);
			}
		}
		RefCounted!(Instance, RefCountedAutoInitialize.no) _instance;
	public:
		/***********************************************************************
		 * Constructor
		 */
		this(in ubyte[] key, in ubyte[] iv, string cmd = defaultOpenSSLCommand)
		{
			import std.format;
			isCommandExisting(cmd).enforce("OpenSSL command line interface cannot find.");
			_instance = refCounted(Instance.init);
			auto encType = key.length == 32 ? "-aes-256-cbc"
				: key.length == 16 ? "-aes-128-cbc"
				: key.length == 24 ? "-aes-192-cbc"
				: "";
			enforce(encType.length > 0, "Unsupported key type.");
			with (_instance.refCountedPayload)
			{
				pipe = pipeProcess([cmd, "enc", encType, "-d", "-in", "-", "-out", "-", "-nopad",
					"-K", format("%(%02X%)", key), "-iv", format("%(%02X%)", iv)]);
				mutex = new Mutex;
				app = appender!(ubyte[]);
				thread = new Thread(&entryConsumer);
				thread.start();
			}
		}
		/***********************************************************************
		 * Update
		 */
		void update(OutputRange)(in ubyte[] data, ref OutputRange dst)
		if (isOutputRange!(OutputRange, ubyte))
		{
			with (_instance.refCountedPayload)
			{
				pipe.stdin.rawWrite(data);
				synchronized (mutex)
				{
					if (app.data.length > 16)
					{
						auto remain = (app.data.length % 16 == 0) ? 16 : app.data.length % 16;
						dst.put(app.data[0..$-remain]);
						app.data[0..remain] = app.data[$-remain .. $];
						app.shrinkTo(remain);
					}
				}
			}
		}
		/***************************************************************************
		 * Finalize
		 */
		void finalize(OutputRange)(ref OutputRange dst, bool padding = true)
		if (isOutputRange!(OutputRange, ubyte))
		{
			with (_instance.refCountedPayload)
			{
				pipe.stdin.flush();
				pipe.stdin.close();
				pipe.pid.wait();
				thread.join();
				if (padding)
				{
					enforce(app.data.length >= 16, "Invalid data received");
					dst.put(app.data[0..$ - app.data[$ - 1]]);
				}
				app.clear();
			}
		}
	}
	private alias OpenSSLCmdAES128CBCDecryptEngine = OpenSSLCmdAESCBCDecryptEngine;
	private alias OpenSSLCmdAES192CBCDecryptEngine = OpenSSLCmdAESCBCDecryptEngine;
	private alias OpenSSLCmdAES256CBCDecryptEngine = OpenSSLCmdAESCBCDecryptEngine;
	
	private struct OpenSSLCmdEd25519Engine
	{
		enum prvKeyLen = 32;
		enum pubKeyLen = 32;
		import std.process;
		struct PrivateKey
		{
		private:
			string _pem;
		public:
			/***********************************************************************
			 * Create new Private Key
			 */
			static PrivateKey createKey(string cmd = defaultOpenSSLCommand)
			{
				isCommandExisting(cmd).enforce("OpenSSL command line interface cannot find.");
				auto result = execute([cmd, "genpkey", "-algorithm", "Ed25519"]);
				enforce(result.status == 0, "Cannot create Ed25519 private key.");
				return PrivateKey(result.output);
			}
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PrivateKey fromPEM(in char[] prvKey)
			{
				return PrivateKey(prvKey.idup);
			}
			/***********************************************************************
			 * Private Key from DER binary
			 */
			static PrivateKey fromDER(in ubyte[] prvKey)
			{
				return PrivateKey(prvKey.der2pem("PRIVATE KEY"));
			}
			/***********************************************************************
			 * Private Key from 256bit binary
			 */
			static PrivateKey fromBinary(in BinaryKey!32 prvKey)
			{
				return fromDER(cast(ubyte[])[
					0x30, 0x2E,       // SEQUENCE: SubjectPrivateKeyInfo (46 bytes)
					  0x02, 0x01, 0x00, // INTEGER (0)
					  0x30, 0x05,       // SEQUENCE Algorithm Identifier (5 bytes)
					    0x06, 0x03, 0x2b, 0x65, 0x70, // OID 1.3.101.112 (Ed25519)
					  0x04, 0x22,       // OCTET STRING (34 bytes)
					    0x04, 0x20] ~ prvKey[0..32]); // 秘密鍵 (32 bytes)
			}
			/***********************************************************************
			 * Private Key to PEM string
			 */
			PEMString toPEM() const
			{
				return _pem;
			}
			/***********************************************************************
			 * Private Key to DER binary
			 */
			DERBinary toDER() const
			{
				return _pem.pem2der();
			}
			/***********************************************************************
			 * Private Key to 256bit binary
			 */
			BinaryKey!32 toBinary() const
			{
				return staticArray!32(toDER()[$-32..$]);
			}
		}
		
		struct PublicKey
		{
		private:
			string _pem;
		public:
			/***********************************************************************
			 * Create new Private Key
			 */
			static PublicKey createKey(PrivateKey prvKey, string cmd = defaultOpenSSLCommand)
			{
				import std.stdio: KeepTerminator;
				import std.algorithm: copy;
				isCommandExisting(cmd).enforce("OpenSSL command line interface cannot find.");
				auto app = appender!(ubyte[]);
				auto dir = createDisposableDir(prefix: "openssl-");
				auto prvKeyPath = dir.write("prvkey.pem", prvKey._pem);
				auto result = execute([cmd, "pkey", "-inform", "PEM", "-in", prvKeyPath, "-pubout"]);
				enforce(result.status == 0, "Cannot create Ed25519 private key.");
				return PublicKey(result.output);
			}
			static PublicKey fromPEM(in char[] pubKey)
			{
				return PublicKey(pubKey.idup);
			}
			static PublicKey fromDER(in ubyte[] pubKey)
			{
				return PublicKey(pubKey.der2pem("PUBLIC KEY"));
			}
			static PublicKey fromBinary(in BinaryKey!32 pubKey)
			{
				return fromDER(cast(ubyte[])[
					0x30, 0x2A,       // SEQUENCE: SubjectPublicKeyInfo (42 bytes)
					  0x30, 0x05,       // SEQUENCE: Algorithm Identifier (5 bytes)
					    0x06, 0x03, 0x2b, 0x65, 0x70, // OID: 1.3.101.112 (Ed25519)
					  0x03, 0x21,       // BIT STRING (33 bytes)
					    0x00] ~ pubKey[0..32]); // 秘密鍵 (32 bytes)
			}
			PEMString toPEM() const
			{
				return _pem;
			}
			DERBinary toDER() const
			{
				return _pem.pem2der();
			}
			BinaryKey!32 toBinary() const
			{
				return staticArray!32(toDER()[$-32..$]);
			}
		}
	private:
		string _cmd = defaultOpenSSLCommand;
	public:
		/***********************************************************************
		 * Constructor
		 */
		this(string cmd)
		{
			_cmd = cmd;
			isCommandExisting(_cmd).enforce("OpenSSL command line interface cannot find.");
		}
		
		/***********************************************************************
		 * 署名
		 */
		bin_t sign(in ubyte[] message, in PrivateKey prvKey)
		{
			import std.algorithm: copy;
			isCommandExisting(_cmd).enforce("OpenSSL command line interface cannot find.");
			auto dir = createDisposableDir(prefix: "openssl-");
			auto prvKeyPath = dir.write("prvkey.pem", prvKey._pem);
			auto messagePath = dir.write("message.bin", message);
			auto pipe = pipeProcess([_cmd, "pkeyutl", "-sign", "-rawin", "-in", messagePath,
				"-inkey", prvKeyPath, "-out", "-"]);
			pipe.stdin.flush();
			pipe.stdin.close();
			auto app = appender!bin_t;
			pipe.stdout.byChunk(4096).copy(app);
			auto result = pipe.pid.wait();
			enforce(result == 0, "Cannot sign specified message.");
			return app.data;
		}
		
		/***********************************************************************
		 * 検証
		 */
		bool verify(in ubyte[] message, in ubyte[] signature, in PublicKey pubKey,
			string cmd = defaultOpenSSLCommand)
		{
			import std.algorithm: copy;
			import std.file, std.path;
			isCommandExisting(_cmd).enforce("OpenSSL command line interface cannot find.");
			auto dir = createDisposableDir(prefix: "openssl-");
			auto pubKeyPath = dir.write("pubkey.pem", pubKey._pem);
			auto msgPath = dir.write("message.bin", message);
			auto signPath = dir.write("signature.bin", signature);
			auto pipe = pipeProcess([_cmd, "pkeyutl", "-verify", "-rawin", "-in", msgPath,
				"-sigfile", signPath, "-pubin", "-inkey", pubKeyPath, "-out", "-"]);
			pipe.stdin.flush();
			pipe.stdin.close();
			auto app = appender!string;
			pipe.stdout.byChunk(4096).copy(app);
			auto result = pipe.pid.wait();
			return result == 0;
		}
	}
	
	private struct OpenSSLCmdECDSAEngine(ECDSAType type = ECDSAType.p256)
	{
		import std.process;
		enum ECDSAType cipherType = type;
		enum size_t cntBits = type == ECDSAType.p256 ? 256
			: type == ECDSAType.p256k ? 256
			: type == ECDSAType.p384 ? 384
			: type == ECDSAType.p521 ? 521
			: 256;
		enum size_t prvKeyLen = type == ECDSAType.p256 ? 32
			: type == ECDSAType.p256k ? 32
			: type == ECDSAType.p384 ? 48
			: type == ECDSAType.p521 ? 66
			: 32;
		enum size_t pubKeyLen = type == ECDSAType.p256 ? 65
			: type == ECDSAType.p256k ? 65
			: type == ECDSAType.p384 ? 97
			: type == ECDSAType.p521 ? 133
			: 65;
		struct PrivateKey
		{
		private:
			PEMString _pem;
		public:
			/*******************************************************************
			 * Create new Private Key
			 */
			static PrivateKey createKey(string cmd = defaultOpenSSLCommand)
			{
				enum curveName = type == ECDSAType.p256 ? "prime256v1"
					: type == ECDSAType.p256k ? "secp256k1"
					: type == ECDSAType.p384 ? "secp384r1"
					: type == ECDSAType.p521 ? "secp521r1"
					: "prime256v1";
				isCommandExisting(cmd).enforce("OpenSSL command line interface cannot find.");
				auto result = execute([cmd, "ecparam", "-name", curveName, "-genkey", "-noout",
					"-out", "-"]);
				enforce(result.status == 0, "Cannot create private key.");
				return PrivateKey(result.output);
			}
			/*******************************************************************
			 * Private Key from PEM string
			 */
			static PrivateKey fromPEM(in char[] prvKey,
				string cmd = defaultOpenSSLCommand)
			{
				return PrivateKey(prvKey.idup);
			}
			/*******************************************************************
			 * Private Key from DER binary
			 */
			static PrivateKey fromDER(in ubyte[] prvKey,
				string cmd = defaultOpenSSLCommand)
			{
				return PrivateKey(prvKey.der2pem("EC PRIVATE KEY"));
			}
			/*******************************************************************
			 * Private Key from 256bit binary
			 */
			static PrivateKey fromBinary(in BinaryKey!prvKeyLen prvKey,
				string cmd = defaultOpenSSLCommand)
			{
				import std.algorithm: copy;
				isCommandExisting(cmd).enforce("OpenSSL Command is not found.");
				auto seq = [0x02, 0x01, 0x01].bin               // INTEGER  VERSION(1)
					~ encasn1ostr(prvKey[0..prvKeyLen])         // OCTET STRING (Private Key)
					~ encasn1(0xA0, encasn1(0x06, getOid!type));// [0] EXPLICIT EC PARAMETERS OID
				auto der = encasn1seq(seq);                     // SEQUENCE
				auto dir = createDisposableDir(prefix: "openssl-");
				auto prvKeyPath = dir.write("prvkey.der", der);
				auto pipe = pipeProcess([cmd, "ec", "-inform", "DER", "-in", prvKeyPath, "-pubout",
					"-outform", "DER", "-out", "-"]);
				pipe.stdin.flush();
				pipe.stdin.close();
				auto app = appender!(ubyte[]);
				pipe.stdout.byChunk(4096).copy(app);
				auto result = pipe.pid.wait();
				enforce(result == 0, "Cannot create private key.");
				const(ubyte)[] pubder = app.data;
				auto pubdat = decasn1seq(pubder);
				auto pubseq = decasn1seq(pubdat);
				return fromDER(encasn1seq(seq ~ encasn1(0xA1, pubdat)));
			}
			/*******************************************************************
			 * Private Key to PEM string
			 */
			PEMString toPEM() const
			{
				return _pem;
			}
			/*******************************************************************
			 * Private Key to DER binary
			 */
			DERBinary toDER() const
			{
				return _pem.pem2der();
			}
			/*******************************************************************
			 * Private Key to raw binary
			 */
			BinaryKey!prvKeyLen toBinary() const
			{
				const(ubyte)[] der = toDER();
				auto seq = decasn1seq(der);
				auto ver = decasn1bn(seq);
				auto key = decasn1ostr(seq);
				assert(key.length == prvKeyLen);
				return staticArray!prvKeyLen(key[0..prvKeyLen]);
			}
		}
		struct PublicKey
		{
		private:
			string _pem;
		public:
			/*******************************************************************
			 * Create new Public Key
			 */
			static PublicKey createKey(PrivateKey prvKey, string cmd = defaultOpenSSLCommand)
			{
				import std.stdio: KeepTerminator;
				import std.algorithm: copy;
				isCommandExisting(cmd).enforce("OpenSSL command line interface cannot find.");
				auto dir = createDisposableDir(prefix: "openssl-");
				auto prvKeyPath = dir.write("prvkey.pem", prvKey._pem);
				auto pipe = pipeProcess([cmd, "ec", "-inform", "PEM", "-in", prvKeyPath,
					"-pubout", "-outform", "PEM", "-out", "-"]);
				auto app = appender!(ubyte[]);
				pipe.stdin.flush();
				pipe.stdin.close();
				pipe.stdout.byChunk(4096).copy(app);
				enforce(pipe.pid.wait() == 0, "Cannot create public key.");
				return PublicKey(cast(string)app.data);
			}
			/*******************************************************************
			 * Public Key from PEM string
			 */
			static PublicKey fromPEM(in char[] pubKey)
			{
				return PublicKey(pubKey.idup);
			}
			/*******************************************************************
			 * Public Key from DER binary
			 */
			static PublicKey fromDER(in ubyte[] pubKey)
			{
				return PublicKey(pubKey.der2pem("PUBLIC KEY"));
			}
			/*******************************************************************
			 * Public Key from 256bit binary
			 */
			static PublicKey fromBinary(in BinaryKey!pubKeyLen pubKey)
			{
				return fromDER(encasn1seq(                      // SEQUENCE
					encasn1seq(                                 // SEQUENCE
						encasn1(0x06, x"2A8648CE3D0201".bin)    // OID: 1.2.840.10045.2.1 (EC Public Key)
						~ encasn1(0x06, getOid!type))           // OID: Curve type / ex) 1.2.840.10045.3.1.7 (P-256)
					~ encasn1str(pubKey[0..pubKeyLen])));       // 公開鍵 (65 bytes)
			}
			/*******************************************************************
			 * Public Key to PEM string
			 */
			PEMString toPEM() const
			{
				return _pem;
			}
			/*******************************************************************
			 * Public Key to DER binary
			 */
			DERBinary toDER() const
			{
				return _pem.pem2der();
			}
			/*******************************************************************
			 * Public Key to 256bit binary
			 */
			BinaryKey!pubKeyLen toBinary() const
			{
				return staticArray!pubKeyLen(toDER()[$-pubKeyLen..$]);
			}
		}
		
	private:
		string _cmd = defaultOpenSSLCommand;
	public:
		/***********************************************************************
		 * Constructor
		 */
		this(string cmd)
		{
			_cmd = cmd;
			isCommandExisting(_cmd).enforce("OpenSSL command line interface cannot find.");
		}
		
		/***********************************************************************
		 * 署名
		 */
		bin_t sign(in ubyte[] message, in PrivateKey prvKey)
		{
			import std.algorithm: copy;
			isCommandExisting(_cmd).enforce("OpenSSL command line interface cannot find.");
			auto dir = createDisposableDir(prefix: "openssl-");
			auto prvKeyPath = dir.write("prvkey.pem", prvKey._pem);
			auto messagePath = dir.write("message.bin", message);
			auto pipe = pipeProcess([_cmd, "pkeyutl", "-sign", "-in", messagePath,
				"-inkey", prvKeyPath, "-out", "-"]);
			pipe.stdin.flush();
			pipe.stdin.close();
			auto app = appender!(immutable(ubyte)[]);
			pipe.stdout.byChunk(4096).copy(app);
			auto result = pipe.pid.wait();
			enforce(result == 0, "Cannot sign specified message.");
			return app.data.convECDSASignDer2Bin();
		}
		
		/***********************************************************************
		 * 検証
		 */
		bool verify(in ubyte[] message, in ubyte[] signature, in PublicKey pubKey)
		{
			import std.algorithm: copy;
			import std.file, std.path;
			isCommandExisting(_cmd).enforce("OpenSSL command line interface cannot find.");
			auto dir = createDisposableDir(prefix: "openssl-");
			auto pubKeyPath = dir.write("pubkey.pem", pubKey._pem);
			auto msgPath = dir.write("message.bin", message);
			auto signPath = dir.write("signature.bin", signature.convECDSASignBin2Der());
			auto pipe = pipeProcess([_cmd, "pkeyutl", "-verify", "-in", msgPath,
				"-sigfile", signPath, "-pubin", "-inkey", pubKeyPath, "-out", "-"]);
			pipe.stdin.flush();
			pipe.stdin.close();
			auto app = appender!string;
			pipe.stdout.byChunk(4096).copy(app);
			auto result = pipe.pid.wait();
			return result == 0;
		}
	}
	
	///
	alias OpenSSLCmdECDSAP256Engine = OpenSSLCmdECDSAEngine!(ECDSAType.p256);
	///
	alias OpenSSLCmdECDSAP256KEngine = OpenSSLCmdECDSAEngine!(ECDSAType.p256k);
	///
	alias OpenSSLCmdECDSAP384Engine = OpenSSLCmdECDSAEngine!(ECDSAType.p384);
	///
	alias OpenSSLCmdECDSAP521Engine = OpenSSLCmdECDSAEngine!(ECDSAType.p521);
	
	private struct OpenSSLCmdRSA4096Engine
	{
		import std.process;
		struct PrvDat
		{
			ubyte[512] modulus;		     // n
			ubyte[4]   publicExponent;      // e
			ubyte[512] privateExponent;     // d
			ubyte[256] prime1;              // p
			ubyte[256] prime2;              // q
			ubyte[256] exponent1;           // d mod (p-1)
			ubyte[256] exponent2;           // d mod (q-1)
			ubyte[256] coefficient;         // q^(-1) mod p
		}
		struct PubDat
		{
			ubyte[512] modulus;             // n
			ubyte[4]   publicExponent;      // e
		}
		enum prvKeyLen = PrvDat.sizeof;
		enum pubKeyLen = PubDat.sizeof;
		/***********************************************************************
		 * RSA4096 Private Key
		 */
		struct PrivateKey
		{
		private:
			string _pem;
		public:
			/*******************************************************************
			 * Create new Private Key
			 */
			static PrivateKey createKey(string cmd = defaultOpenSSLCommand)
			{
				import std.algorithm: copy;
				isCommandExisting(cmd).enforce("OpenSSL command line interface cannot find.");
				auto pipe = getOpenSSLCmdVerseion(cmd) < SemVer(3, 0, 0)
					? pipeProcess([cmd, "genrsa", "4096"])
					: pipeProcess([cmd, "genrsa", "-traditional", "4096"]);
				pipe.stdin.flush();
				pipe.stdin.close();
				auto app = appender!string;
				pipe.stdout.byChunk(4096).copy(app);
				enforce(pipe.pid.wait() == 0, "Cannot create private key.");
				return PrivateKey(app.data);
			}
			/*******************************************************************
			 * Private Key from PEM string
			 */
			static PrivateKey fromPEM(in char[] prvKey,
				string cmd = defaultOpenSSLCommand)
			{
				return PrivateKey(prvKey.idup);
			}
			/***********************************************************************
			 * Private Key from DER binary
			 */
			static PrivateKey fromDER(in ubyte[] prvKey,
				string cmd = defaultOpenSSLCommand)
			{
				return PrivateKey(prvKey.der2pem("RSA PRIVATE KEY"));
			}
			/***********************************************************************
			 * Private Key from raw binary
			 */
			static PrivateKey fromBinary(in BinaryKey!prvKeyLen prvKey,
				string cmd = defaultOpenSSLCommand)
			{
				auto prvKeyDat = cast(PrvDat*)prvKey.ptr;
				auto derseq = cast(immutable(ubyte)[])[0x02, 0x01, 0x00]
					~ encasn1bn(prvKeyDat.modulus[])
					~ encasn1bn(prvKeyDat.publicExponent[])
					~ encasn1bn(prvKeyDat.privateExponent[])
					~ encasn1bn(prvKeyDat.prime1[])
					~ encasn1bn(prvKeyDat.prime2[])
					~ encasn1bn(prvKeyDat.exponent1[])
					~ encasn1bn(prvKeyDat.exponent2[])
					~ encasn1bn(prvKeyDat.coefficient[]);
				return fromDER(encasn1seq(derseq));
			}
			/***********************************************************************
			 * Private Key to PEM string
			 */
			PEMString toPEM(string cmd = defaultOpenSSLCommand) const
			{
				return _pem;
			}
			/***********************************************************************
			 * Private Key to DER binary
			 */
			DERBinary toDER(string cmd = defaultOpenSSLCommand) const
			{
				return _pem.pem2der();
			}
			/***********************************************************************
			 * Private Key to raw binary
			 */
			BinaryKey!prvKeyLen toBinary(string cmd = defaultOpenSSLCommand) const
			{
				BinaryKey!prvKeyLen ret;
				auto dat = cast(PrvDat*)ret.ptr;
				const(ubyte)[] derall = toDER();
				auto der = decasn1seq(derall);
				auto ver = decasn1bn(der);
				enforce(ver.length == 1 && ver[0] == 0x00, "Invalid private key format.");
				dat.modulus[0..512]         = decasn1bn(der, 512)[0..512];
				dat.publicExponent[0..4]    = decasn1bn(der, 4)[0..4];
				dat.privateExponent[0..512] = decasn1bn(der, 512)[0..512];
				dat.prime1[0..256]          = decasn1bn(der, 256)[0..256];
				dat.prime2[0..256]          = decasn1bn(der, 256)[0..256];
				dat.exponent1[0..256]       = decasn1bn(der, 256)[0..256];
				dat.exponent2[0..256]       = decasn1bn(der, 256)[0..256];
				dat.coefficient[0..256]     = decasn1bn(der, 256)[0..256];
				return ret;
			}
		}
		/***********************************************************************
		 * RSA4096 Public Key
		 */
		struct PublicKey
		{
		private:
			string _pem;
		public:
			/*******************************************************************
			 * Create new Public Key
			 */
			static PublicKey createKey(PrivateKey prvKey, string cmd = defaultOpenSSLCommand)
			{
				import std.stdio: KeepTerminator;
				import std.algorithm: copy;
				isCommandExisting(cmd).enforce("OpenSSL command line interface cannot find.");
				auto dir = createDisposableDir(prefix: "openssl-");
				auto prvKeyPath = dir.write("prvkey.pem", prvKey._pem);
				auto pipe = pipeProcess([cmd, "rsa", "-inform", "PEM", "-in", prvKeyPath,
					"-pubout", "-outform", "PEM", "-out", "-"]);
				auto app = appender!(ubyte[]);
				pipe.stdin.flush();
				pipe.stdin.close();
				pipe.stdout.byChunk(4096).copy(app);
				enforce(pipe.pid.wait() == 0, "Cannot create public key.");
				return PublicKey(cast(string)app.data);
			}
			/*******************************************************************
			 * Public Key from PEM string
			 */
			static PublicKey fromPEM(in char[] pubKey)
			{
				return PublicKey(pubKey.idup);
			}
			/*******************************************************************
			 * Public Key from DER binary
			 */
			static PublicKey fromDER(in ubyte[] pubKey)
			{
				return PublicKey(pubKey.der2pem("PUBLIC KEY"));
			}
			/*******************************************************************
			 * Public Key from raw binary
			 */
			static PublicKey fromBinary(in BinaryKey!pubKeyLen pubKey)
			{
				auto pubKeyDat = cast(PrvDat*)pubKey.ptr;
				return fromDER(encasn1seq(
					encasn1seq(cast(ubyte[])[0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
					~ encasn1str(encasn1seq(
						encasn1bn(pubKeyDat.modulus[])
						~ encasn1bn(pubKeyDat.publicExponent[])))));
			}
			/***********************************************************************
			 * Public Key to PEM string
			 */
			PEMString toPEM() const
			{
				return _pem;
			}
			/***********************************************************************
			 * Public Key to DER binary
			 */
			DERBinary toDER() const
			{
				return _pem.pem2der();
			}
			/***********************************************************************
			 * Public Key to raw binary
			 */
			BinaryKey!pubKeyLen toBinary() const
			{
				BinaryKey!pubKeyLen ret;
				auto dat = cast(PubDat*)ret.ptr;
				const(ubyte)[] derall = toDER();
				auto derseq = decasn1seq(derall);
				auto objId  = decasn1seq(derseq);
				auto contentStr  = decasn1str(derseq);
				auto pubKeyDat   = decasn1seq(contentStr);
				dat.modulus[0..512]      = decasn1bn(pubKeyDat, 512)[0..512];
				dat.publicExponent[0..4] = decasn1bn(pubKeyDat, 4)[0..4];
				return ret;
			}
		}
		
	private:
		string _cmd = defaultOpenSSLCommand;
	public:
		/***********************************************************************
		 * Constructor
		 */
		this(string cmd)
		{
			_cmd = cmd;
			isCommandExisting(_cmd).enforce("OpenSSL command line interface cannot find.");
		}
		
		/***********************************************************************
		 * 署名
		 */
		bin_t sign(in ubyte[] message, in PrivateKey prvKey)
		{
			// openssl pkeyutl -sign -inkey private_key_rsa4096.pem -in test.txt -out -
			import std.algorithm: copy;
			auto dir = createDisposableDir(prefix: "openssl-");
			auto prvKeyPath = dir.write("prvkey.pem", prvKey._pem);
			auto pipe = pipeProcess([_cmd, "pkeyutl", "-sign", "-inkey", prvKeyPath,
				"-in", "-", "-out", "-"]);
			pipe.stdin.rawWrite(message);
			pipe.stdin.flush();
			pipe.stdin.close();
			auto app = appender!(immutable(ubyte)[]);
			pipe.stdout.byChunk(4096).copy(app);
			auto result = pipe.pid.wait();
			enforce(result == 0, "Cannot sign specified message.");
			return app.data;
		}
		
		/***********************************************************************
		 * 検証
		 */
		bool verify(in ubyte[] message, in ubyte[] signature, in PublicKey pubKey)
		{
			import std.algorithm: copy;
			import std.file, std.path;
			auto dir = createDisposableDir(prefix: "openssl-");
			auto pubKeyPath = dir.write("pubkey.pem", pubKey._pem);
			auto signPath = dir.write("signature.bin", signature);
			auto pipe = pipeProcess([_cmd, "pkeyutl", "-verify", "-pubin", "-inkey", pubKeyPath,
				"-in", "-", "-sigfile", signPath, "-out", "-"]);
			pipe.stdin.rawWrite(message);
			pipe.stdin.flush();
			pipe.stdin.close();
			auto app = appender!string;
			pipe.stdout.byChunk(4096).copy(app);
			auto result = pipe.pid.wait();
			return result == 0;
		}
		
		/***********************************************************************
		 * 暗号化
		 */
		bin_t encrypt(in ubyte[] data, in PublicKey pubKey)
		{
			import std.algorithm: copy;
			auto dir = createDisposableDir(prefix: "openssl-");
			auto pubKeyPath = dir.write("pubkey.pem", pubKey._pem);
			// openssl pkeyutl -encrypt -pubin -inkey public_key_rsa4096.pem -in test.txt -out -
			auto pipe = pipeProcess([_cmd, "pkeyutl", "-encrypt", "-pubin", "-inkey", pubKeyPath,
				"-in", "-", "-out", "-"]);
			pipe.stdin.rawWrite(data);
			pipe.stdin.flush();
			pipe.stdin.close();
			auto app = appender!(immutable(ubyte)[]);
			pipe.stdout.byChunk(4096).copy(app);
			auto result = pipe.pid.wait();
			enforce(result == 0, "Cannot encrypt specified data.");
			return app.data;
		}
		
		/***********************************************************************
		 * 復号
		 */
		bin_t decrypt(in ubyte[] data, in PrivateKey prvKey)
		{
			import std.algorithm: copy;
			import std.file, std.path;
			// openssl pkeyutl -decrypt -inkey private_key_rsa4096.pem -in test-enc.bin -out -
			auto dir = createDisposableDir(prefix: "openssl-");
			auto prvKeyPath = dir.write("pubkey.pem", prvKey._pem);
			auto pipe = pipeProcess([_cmd, "pkeyutl", "-decrypt", "-inkey", prvKeyPath,
				"-in", "-", "-out", "-"]);
			pipe.stdin.rawWrite(data);
			pipe.stdin.flush();
			pipe.stdin.close();
			auto app = appender!(immutable(ubyte)[]);
			pipe.stdout.byChunk(4096).copy(app);
			auto result = pipe.pid.wait();
			return app.data;
		}
	}
	
	private struct OpenSSLCmdECDHP256Engine
	{
		enum prvKeyLen = 32;
		enum pubKeyLen = 65;
		import std.process;
		alias PrivateKey = OpenSSLCmdECDSAP256Engine.PrivateKey;
		alias PublicKey  = OpenSSLCmdECDSAP256Engine.PublicKey;
	private:
		string _cmd = defaultOpenSSLCommand;
	public:
		/***********************************************************************
		 * Constructor
		 */
		this(string cmd)
		{
			_cmd = cmd;
			isCommandExisting(_cmd).enforce("OpenSSL command line interface cannot find.");
		}
		
		/***********************************************************************
		 * Derive shared secret
		 */
		bin_t derive(in PrivateKey prvKey, in PublicKey pubKey)
		{
			import std.algorithm: copy;
			isCommandExisting(_cmd).enforce("OpenSSL command line interface cannot find.");
			auto dir = createDisposableDir(prefix: "openssl-");
			auto prvKeyPath = dir.write("prvkey.pem", prvKey._pem);
			auto pubKeyPath = dir.write("pubkey.pem", pubKey._pem);
			auto pipe = pipeProcess([_cmd, "pkeyutl", "-derive",
				"-inkey", prvKeyPath, "-peerkey", pubKeyPath, "-out", "-"]);
			pipe.stdin.flush();
			pipe.stdin.close();
			auto app = appender!(immutable(ubyte)[]);
			pipe.stdout.byChunk(4096).copy(app);
			auto result = pipe.pid.wait();
			enforce(result == 0, "Cannot derive shared secret.");
			return app.data;
		}
	}
}

//##############################################################################
//##### OpenSSL Engines
//##############################################################################
static if (enableOpenSSLEngines)
{
	import deimos.openssl.evp;
	
	private void evpEnforce(int resultValue, string message, string f = __FILE__, size_t l = __LINE__)
	{
		cast(void)enforce(resultValue > 0, message, f, l);
	}
	///
	private struct OpenSSLAESCBCEncryptEngine
	{
	private:
		import std.range;
		EVP_CIPHER_CTX* _ctx;
	public:
		/***********************************************************************
		 * Constructor
		 */
		this(in ubyte[] key, in ubyte[] iv) @trusted
		{
			_ctx = EVP_CIPHER_CTX_new().enforce("Cannot create cipher context.");
			// 初期化
			_ctx.EVP_EncryptInit_ex(
				key.length == 32 ? EVP_aes_256_cbc() : key.length == 24 ? EVP_aes_192_cbc() : EVP_aes_128_cbc(),
				null, key.ptr, iv.ptr).evpEnforce("Cannot create cipher context.");
		}
		/***********************************************************************
		 * Destructor
		 */
		~this() @trusted
		{
			if (_ctx)
				EVP_CIPHER_CTX_free(_ctx);
		}
		/***********************************************************************
		 * Update
		 */
		void update(OutputRange)(in ubyte[] data, ref OutputRange dst)
		if (isOutputRange!(OutputRange, ubyte))
		{
			import core.stdc.stdlib: malloc, free;
			ubyte* outData = cast(ubyte*)malloc(data.length);
			scope (exit)
				outData.free();
			int outLen = 0;
			EVP_EncryptUpdate(_ctx, outData, &outLen, data.ptr, cast(int)data.length)
				.evpEnforce("AES128 CBC encryption failed.");
			dst.put(outData[0 .. outLen]);
		}
		/***********************************************************************
		 * Finalize
		 */
		void finalize(OutputRange)(ref OutputRange dst, bool padding = true)
		if (isOutputRange!(OutputRange, ubyte))
		{
			if (!padding)
				return;
			ubyte[16] outData;
			int outLen = 0;
			EVP_EncryptFinal_ex(_ctx, outData.ptr, &outLen)
				.evpEnforce("AES128 CBC encryption failed.");
			dst.put(outData[0 .. outLen]);
		}
	}
	///
	private alias OpenSSLAES128CBCEncryptEngine = OpenSSLAESCBCEncryptEngine;
	///
	private alias OpenSSLAES192CBCEncryptEngine = OpenSSLAESCBCEncryptEngine;
	///
	private alias OpenSSLAES256CBCEncryptEngine = OpenSSLAESCBCEncryptEngine;
	///
	private struct OpenSSLAESCBCDecryptEngine
	{
	private:
		import std.range;
		EVP_CIPHER_CTX* _ctx;
		ubyte[16] _remain;
		ubyte     _remainNum;
		size_t    _inLen;
		size_t    _outLen;
	public:
		/***********************************************************************
		 * Constructor
		 */
		this(in ubyte[] key, in ubyte[] iv) @trusted
		{
			_ctx = EVP_CIPHER_CTX_new().enforce("Cannot create OpenSSL cipher context.");
			// 初期化
			_ctx.EVP_DecryptInit_ex(
				key.length == 32 ? EVP_aes_256_cbc() : key.length == 24 ? EVP_aes_192_cbc() : EVP_aes_128_cbc(),
				null, key.ptr, iv.ptr).evpEnforce("Cannot initialize cipher context.");
		}
		/***********************************************************************
		 * Destructor
		 */
		~this() @trusted
		{
			if (_ctx)
				EVP_CIPHER_CTX_free(_ctx);
		}
		/***********************************************************************
		 * Update
		 */
		void update(OutputRange)(in ubyte[] data, ref OutputRange dst)
		if (isOutputRange!(OutputRange, ubyte))
		{
			import core.stdc.stdlib: malloc, free;
			const(ubyte)[] src;
			if (_remainNum != 0)
			{
				if (data.length < _remain.length - _remainNum)
				{
					_remain[_remainNum .. _remainNum + data.length] = data[];
					_remainNum += cast(ubyte)data.length;
					return;
				}
				_remain[_remainNum .. $] = data[0 .. _remain.length - _remainNum];
				src = data[_remain.length - _remainNum .. $];
				
				ubyte[32] outData;
				int outLen = 0;
				
				EVP_DecryptUpdate(_ctx, outData.ptr, &outLen, _remain.ptr, cast(int)_remain.length)
					.evpEnforce("AES128 CBC decryption failed.");
				_inLen += _remain.length;
				_outLen += outLen;
				if (outLen != 0)
					dst.put(outData[0..outLen]);
			}
			else
			{
				src = data[];
			}
			_remainNum = cast(ubyte)(src.length % 16);
			_remain[0 .. _remainNum] = src[$ - _remainNum .. $];
			src = src[0..$ - _remainNum];
			
			if (src.length == 0)
				return;
			assert(src.length % 16 == 0);
			ubyte* outData = cast(ubyte*)malloc(src.length + 16);
			scope (exit)
				outData.free();
			int outLen = 0;
			EVP_DecryptUpdate(_ctx, outData, &outLen, src.ptr, cast(int)src.length)
				.evpEnforce("AES128 CBC decryption failed.");
			_inLen += src.length;
			_outLen += outLen;
			if (outLen != 0)
				dst.put(outData[0..outLen]);
		}
		/***********************************************************************
		 * Finalize
		 */
		void finalize(OutputRange)(ref OutputRange dst, bool padding = true)
		if (isOutputRange!(OutputRange, ubyte))
		{
			if (!padding)
			{
				if (_outLen < _inLen)
				{
					ubyte[16] outData;
					int outLen = 0;
					EVP_DecryptUpdate(_ctx, outData.ptr, &outLen, null, 0)
						.evpEnforce("OpenSSL AES128 CBC decryption failed.");
					dst.put(outData[0 .. $]);
					_outLen += 16;
				}
				return;
			}
			if (_outLen < _inLen)
			{
				ubyte[16] outData;
				int outLen = 0;
				EVP_DecryptUpdate(_ctx, outData.ptr, &outLen, null, 0)
					.evpEnforce("OpenSSL AES128 CBC decryption failed.");
				EVP_DecryptFinal_ex(_ctx, outData.ptr, &outLen)
					.evpEnforce("OpenSSL AES128 CBC decryption failed.");
				dst.put(outData[0 .. outLen]);
				_outLen += outLen;
			}
		}
	}
	///
	private alias OpenSSLAES128CBCDecryptEngine = OpenSSLAESCBCDecryptEngine;
	///
	private alias OpenSSLAES192CBCDecryptEngine = OpenSSLAESCBCDecryptEngine;
	///
	private alias OpenSSLAES256CBCDecryptEngine = OpenSSLAESCBCDecryptEngine;
	///
	private struct OpenSSLEd25519Engine
	{
		enum prvKeyLen = 32;
		enum pubKeyLen = 32;
		struct PrivateKey
		{
		private:
			import std.typecons: RefCounted, RefCountedAutoInitialize, refCounted;
			struct Instance
			{
				EVP_PKEY* _key;
				@disable this(this);
				~this() @trusted
				{
					if (_key)
						EVP_PKEY_free(_key);
				}
			}
			RefCounted!(Instance, RefCountedAutoInitialize.no) _instance;
			static PrivateKey makeInst(EVP_PKEY* key)
			{
				return PrivateKey(refCounted(Instance(key)));
			}
			inout(EVP_PKEY)* _key() inout
			{
				return _instance._key;
			}
		public:
			/***********************************************************************
			 * Create new Private Key
			 */
			static PrivateKey createKey()
			{
				auto ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_ED25519, null).enforce("Cannot create private key.");
				scope (exit)
					ctx.EVP_PKEY_CTX_free();
				ctx.EVP_PKEY_keygen_init();
				EVP_PKEY* pkey;
				ctx.EVP_PKEY_keygen(&pkey).evpEnforce("Cannot create private key.");
				return makeInst(pkey);
			}
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PrivateKey fromPEM(in char[] prvKey)
			{
				import deimos.openssl.bio;
				import deimos.openssl.pem;
				// PEM形式の文字列をBIOメモリストリームに読み込む
				auto bio = BIO_new_mem_buf(cast(void*)prvKey.ptr, cast(int)prvKey.length)
					.enforce("Cannot create specified private key.");
				scope (exit)
					bio.BIO_free();
				return makeInst(PEM_read_bio_PrivateKey(bio, null, null, null));
			}
			/***********************************************************************
			 * Private Key from DER binary
			 */
			static PrivateKey fromDER(in ubyte[] prvKey)
			{
				// 秘密鍵を読み込み
				auto pBuf = prvKey.ptr;
				return makeInst(d2i_PrivateKey(EVP_PKEY_ED25519, null, &pBuf, cast(int)prvKey.length)
					.enforce("Cannot convert specified private key."));
			}
			/***********************************************************************
			 * Private Key from 256bit binary
			 */
			static PrivateKey fromBinary(in BinaryKey!32 prvKey)
			{
				return makeInst(EVP_PKEY_new_raw_private_key(EVP_PKEY_ED25519, null, prvKey.ptr, prvKey.length)
					.enforce("Cannot convert specified private key."));
			}
			/***********************************************************************
			 * Private Key to PEM string
			 */
			PEMString toPEM() const
			{
				import deimos.openssl.pem;
				// BIOメモリバッファを作成
				auto mem = BIO_new(BIO_s_mem()).enforce("Cannot convert specified private key.");
				scope (exit)
					mem.BIO_free();
				// PEM形式で秘密鍵を書き込む
				PEM_write_bio_PrivateKey(mem, cast(EVP_PKEY*)_key, null, null, 0, null, null)
					.evpEnforce("Cannot convert specified private key.");
				// 文字列の取り出し
				ubyte* pemData = null;
				auto pemLen = BIO_get_mem_data(mem, &pemData);
				auto pemStr = new char[pemLen];
				pemStr[0..pemLen] = cast(char[])pemData[0..pemLen];
				return pemStr.assumeUnique;
			}
			/***********************************************************************
			 * Private Key to DER binary
			 */
			DERBinary toDER() const
			{
				// 秘密鍵をDER形式に保存
				auto derlen = i2d_PrivateKey(cast(EVP_PKEY*)_key, null)
					.enforce("Cannot create specified private key.");
				auto derPrvKey = new ubyte[derlen];
				auto pBuf = derPrvKey.ptr;
				i2d_PrivateKey(cast(EVP_PKEY*)_key, &pBuf).evpEnforce("Cannot create specified private key.");
				return derPrvKey.assumeUnique;
			}
			/***********************************************************************
			 * Private Key to 256bit binary
			 */
			BinaryKey!32 toBinary() const
			{
				// 生の鍵を取り出す
				size_t len;
				EVP_PKEY_get_raw_private_key(cast(EVP_PKEY*)_key, null, &len)
					.evpEnforce("Cannot convert specified private key.");
				assert(len == 32);
				BinaryKey!32 prvKeyRaw;
				EVP_PKEY_get_raw_private_key(cast(EVP_PKEY*)_key, prvKeyRaw.ptr, &len)
					.evpEnforce("Cannot convert specified private key.");
				return prvKeyRaw;
			}
		}
		
		struct PublicKey
		{
		private:
			import std.typecons: RefCounted, RefCountedAutoInitialize, refCounted;
			struct Instance
			{
				EVP_PKEY* _key;
				@disable this(this);
				~this() @trusted
				{
					if (_key)
						EVP_PKEY_free(_key);
				}
			}
			RefCounted!(Instance, RefCountedAutoInitialize.no) _instance;
			static PublicKey makeInst(EVP_PKEY* key)
			{
				return PublicKey(refCounted(Instance(key)));
			}
			inout(EVP_PKEY)* _key() inout
			{
				return _instance._key;
			}
		public:
			/***********************************************************************
			 * Create new Private Key
			 */
			static PublicKey createKey(PrivateKey prvKey)
			{
				// 生の鍵を取り出す
				size_t len;
				EVP_PKEY_get_raw_public_key(cast(EVP_PKEY*)prvKey._key, null, &len)
					.evpEnforce("Cannot create public key.");
				assert(len == 32);
				ubyte[32] pubKeyRaw;
				EVP_PKEY_get_raw_public_key(cast(EVP_PKEY*)prvKey._key, pubKeyRaw.ptr, &len)
					.evpEnforce("Cannot create public key.");
				return makeInst(EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, null, pubKeyRaw.ptr, pubKeyRaw.length)
					.enforce("Cannot create private key."));
			}
			static PublicKey fromPEM(in char[] pubKey)
			{
				import deimos.openssl.bio;
				import deimos.openssl.pem;
				// PEM形式の文字列をBIOメモリストリームに読み込む
				auto bio = BIO_new_mem_buf(cast(void*)pubKey.ptr, cast(int)pubKey.length)
					.enforce("Cannot create specified private key.");
				scope (exit)
					bio.BIO_free();
				return makeInst(PEM_read_bio_PUBKEY(bio, null, null, null));
			}
			static PublicKey fromDER(in ubyte[] pubKey)
			{
				import deimos.openssl.x509;
				// 公開鍵を読み込み
				auto pBuf = pubKey.ptr;
				return makeInst(d2i_PUBKEY(null, &pBuf, cast(int)pubKey.length)
					.enforce("Cannot convert specified private key."));
			}
			static PublicKey fromBinary(in BinaryKey!32 pubKey)
			{
				return makeInst(EVP_PKEY_new_raw_public_key(EVP_PKEY_ED25519, null, pubKey.ptr, pubKey.length)
					.enforce("Cannot convert specified private key."));
			}
			PEMString toPEM() const
			{
				import deimos.openssl.pem;
				// BIOメモリバッファを作成
				auto mem = BIO_new(BIO_s_mem()).enforce("Cannot convert specified private key.");
				scope (exit)
					mem.BIO_free();
				// PEM形式で公開鍵を書き込む
				PEM_write_bio_PUBKEY(mem, cast(EVP_PKEY*)_key).evpEnforce("Cannot convert specified private key.");
				// 文字列の取り出し
				ubyte* pemData = null;
				auto pemLen = BIO_get_mem_data(mem, &pemData);
				auto pemStr = new char[pemLen];
				pemStr[0..pemLen] = cast(char[])pemData[0..pemLen];
				return pemStr.assumeUnique;
			}
			DERBinary toDER() const
			{
				// 公開鍵をDER形式に保存
				import deimos.openssl.x509;
				auto derlen = i2d_PUBKEY(cast(EVP_PKEY*)_key, null).enforce("Cannot create specified private key.");
				auto derPubKey = new ubyte[derlen];
				auto pBuf = derPubKey.ptr;
				i2d_PUBKEY(cast(EVP_PKEY*)_key, &pBuf).enforce("Cannot create specified private key.");
				return derPubKey.assumeUnique;
			}
			BinaryKey!32 toBinary() const
			{
				// 生の鍵を取り出す
				size_t len;
				EVP_PKEY_get_raw_public_key(cast(EVP_PKEY*)_key, null, &len)
					.evpEnforce("Cannot convert specified public key.");
				assert(len == 32);
				BinaryKey!32 pubKeyRaw;
				EVP_PKEY_get_raw_public_key(cast(EVP_PKEY*)_key, pubKeyRaw.ptr, &len)
					.evpEnforce("Cannot convert specified public key.");
				return pubKeyRaw;
			}
		}
		/***********************************************************************
		 * 署名
		 */
		bin_t sign(in ubyte[] message, in PrivateKey prvKey)
		{
			// 初期化
			auto ctxSign = EVP_MD_CTX_new().enforce("OpenSSL Ed25519 sign failed.");
			scope (exit)
				ctxSign.EVP_MD_CTX_free();
			ctxSign.EVP_DigestSignInit(null, null, null, cast(EVP_PKEY*)prvKey._key)
				.evpEnforce("OpenSSL Ed25519 sign failed.");
			
			// 署名のサイズを取得してバッファを作成
			size_t signLen;
			ctxSign.EVP_DigestSign(null, &signLen, null, 0);
			auto signData = new ubyte[signLen];
			
			// 署名のためのハッシュ計算
			ctxSign.EVP_DigestSign(signData.ptr, &signLen, message.ptr, message.length);
			return signData[0..signLen].assumeUnique;
		}
		
		/***********************************************************************
		 * 検証
		 */
		bool verify(in ubyte[] message, in ubyte[] signature, in PublicKey pubKey)
		{
			// 初期化
			auto ctxVerify = EVP_MD_CTX_new();
			scope (exit)
				ctxVerify.EVP_MD_CTX_free();
			
			// 署名のためのハッシュ計算
			ctxVerify.EVP_DigestVerifyInit(null, null, null, cast(EVP_PKEY*)pubKey._key);
			auto res = ctxVerify.EVP_DigestVerify(signature.ptr, signature.length,
				cast(ubyte*)message.ptr, message.length);
			return res != 0;
		}
	}
	
	private struct OpenSSLECDSAEngine(ECDSAType type)
	{
		enum ECDSAType cipherType = type;
		enum size_t cntBits = type == ECDSAType.p256 ? 256
			: type == ECDSAType.p256k ? 256
			: type == ECDSAType.p384 ? 384
			: type == ECDSAType.p521 ? 521
			: 256;
		enum size_t prvKeyLen = type == ECDSAType.p256 ? 32
			: type == ECDSAType.p256k ? 32
			: type == ECDSAType.p384 ? 48
			: type == ECDSAType.p521 ? 66
			: 32;
		enum size_t pubKeyLen = type == ECDSAType.p256 ? 65
			: type == ECDSAType.p256k ? 65
			: type == ECDSAType.p384 ? 97
			: type == ECDSAType.p521 ? 133
			: 65;
		private enum curveName = type == ECDSAType.p256 ? NID_X9_62_prime256v1
			: type == ECDSAType.p256k ? NID_secp256k1
			: type == ECDSAType.p384 ? NID_secp384r1
			: type == ECDSAType.p521 ? NID_secp521r1
			: NID_X9_62_prime256v1;
		/***********************************************************************
		 * ECDSA Private Key
		 */
		struct PrivateKey
		{
		private:
			import std.typecons: RefCounted, RefCountedAutoInitialize, refCounted;
			struct Instance
			{
				EVP_PKEY* _key;
				@disable this(this);
				~this() @trusted
				{
					if (_key)
						EVP_PKEY_free(_key);
				}
			}
			RefCounted!(Instance, RefCountedAutoInitialize.no) _instance;
			static PrivateKey makeInst(EVP_PKEY* key)
			{
				return PrivateKey(refCounted(Instance(key)));
			}
			inout(EVP_PKEY)* _key() inout
			{
				return _instance._key;
			}
		public:
			/***********************************************************************
			 * Create new Private Key
			 */
			static PrivateKey createKey()
			{
				import deimos.openssl.ec;
				auto ctxParam = EVP_PKEY_CTX_new_id(EVP_PKEY_EC, null).enforce("Cannot create private key.");
				EVP_PKEY* params;
				scope (exit)
					ctxParam.EVP_PKEY_CTX_free();
				ctxParam.EVP_PKEY_paramgen_init().evpEnforce("Cannot create private key.");
				ctxParam.EVP_PKEY_CTX_set_ec_paramgen_curve_nid(curveName).evpEnforce("Cannot create private key.");
				ctxParam.EVP_PKEY_paramgen(&params).evpEnforce("Cannot create private key.");
				scope (exit)
					params.EVP_PKEY_free();
				EVP_PKEY* pkey;
				auto ctx = EVP_PKEY_CTX_new(params, null).enforce("Cannot create private key.");
				scope (exit)
					ctx.EVP_PKEY_CTX_free();
				ctx.EVP_PKEY_keygen_init().evpEnforce("Cannot create private key.");
				ctx.EVP_PKEY_keygen(&pkey).evpEnforce("Cannot create private key.");
				return makeInst(pkey);
			}
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PrivateKey fromPEM(in char[] prvKey)
			{
				import deimos.openssl.bio;
				import deimos.openssl.pem;
				// PEM形式の文字列をBIOメモリストリームに読み込む
				auto bio = BIO_new_mem_buf(cast(void*)prvKey.ptr, cast(int)prvKey.length)
					.enforce("Cannot create specified private key.");
				scope (exit)
					bio.BIO_free();
				return makeInst(PEM_read_bio_PrivateKey(bio, null, null, null));
			}
			/***********************************************************************
			 * Private Key from DER binary
			 */
			static PrivateKey fromDER(in ubyte[] prvKey)
			{
				// 秘密鍵を読み込み
				auto pBuf = prvKey.ptr;
				return makeInst(d2i_PrivateKey(EVP_PKEY_EC, null, &pBuf, cast(int)prvKey.length)
					.enforce("Cannot convert specified private key."));
			}
			/***********************************************************************
			 * Private Key from 256bit binary
			 */
			static PrivateKey fromBinary(in BinaryKey!prvKeyLen prvKey)
			{
				import deimos.openssl.ec;
				import deimos.openssl.ecdsa;
				import deimos.openssl.bn;
				auto bn = BN_bin2bn(prvKey.ptr, prvKey.length, null).enforce("Cannot convert specified private key.");
				scope (failure)
					if (bn)
						BN_free(bn);
				auto ecKey = EC_KEY_new_by_curve_name(curveName)
					.enforce("Cannot convert specified private key.");
				scope (failure)
					if (ecKey)
						EC_KEY_free(ecKey);
				EC_KEY_set_private_key(ecKey, bn).enforce("Cannot convert specified private key.");
				auto bnPrv = bn;
				bn = null;
				
				auto ecGroup = EC_KEY_get0_group(ecKey).enforce("Cannot convert specified private key.");
				auto pubPt = EC_POINT_new(ecGroup).enforce("Cannot convert specified private key.");
				scope (failure)
					if (pubPt)
						EC_POINT_free(pubPt);
				EC_POINT_mul(ecGroup, pubPt, bnPrv, null, null, null)
					.evpEnforce("Cannot convert specified private key.");
				EC_KEY_set_public_key(ecKey, pubPt).evpEnforce("Cannot convert specified private key.");
				pubPt = null;
				
				auto pkey = EVP_PKEY_new();
				scope (failure)
					if (pkey)
						EVP_PKEY_free(pkey);
				EVP_PKEY_assign_EC_KEY(pkey, ecKey).enforce("Cannot convert specified private key.");
				ecKey = null;
				
				return makeInst(pkey);
			}
			/***********************************************************************
			 * Private Key to PEM string
			 */
			PEMString toPEM() const
			{
				import deimos.openssl.pem;
				import deimos.openssl.bio;
				import deimos.openssl.ec;
				// BIOメモリバッファを作成
				auto mem = BIO_new(BIO_s_mem()).enforce("Cannot convert specified private key.");
				scope (exit)
					mem.BIO_free();
				// PEM形式で秘密鍵を書き込む
				auto ecKey = EVP_PKEY_get1_EC_KEY(cast(EVP_PKEY*)_key).enforce("Cannot convert specified private key.");
				PEM_write_bio_ECPrivateKey(mem, ecKey, null, null, 0, null, null)
					.evpEnforce("Cannot convert specified private key.");
				// 文字列の取り出し
				ubyte* pemData = null;
				auto pemLen = BIO_get_mem_data(mem, &pemData);
				auto pemStr = new char[pemLen];
				pemStr[0..pemLen] = cast(char[])pemData[0..pemLen];
				return pemStr.assumeUnique;
			}
			/***********************************************************************
			 * Private Key to DER binary
			 */
			DERBinary toDER() const
			{
				auto derlen = i2d_PrivateKey(cast(EVP_PKEY*)_key, null).enforce("Cannot create specified private key.");
				auto derPrvKey = new ubyte[derlen];
				auto pBuf = derPrvKey.ptr;
				i2d_PrivateKey(cast(EVP_PKEY*)_key, &pBuf).evpEnforce("Cannot create specified private key.");
				return derPrvKey.assumeUnique;
			}
			/***********************************************************************
			 * Private Key to 256bit binary
			 */
			BinaryKey!prvKeyLen toBinary() const
			{
				import deimos.openssl.ec;
				auto ecKey = EVP_PKEY_get1_EC_KEY(cast(EVP_PKEY*)_key).enforce("Cannot create specified private key.");
				auto group = EC_KEY_get0_group(ecKey).enforce("Cannot create specified private key.");
				auto bn = EC_KEY_get0_private_key(ecKey).enforce("Cannot create specified private key.");
				ubyte[prvKeyLen] prvKeyRaw;
				auto len = BN_bn2bin(bn, prvKeyRaw.ptr).enforce("Cannot create specified private key.");
				import std.algorithm: bringToFront;
				bringToFront(prvKeyRaw[0..len], prvKeyRaw[len..$]);
				assert(len <= prvKeyLen);
				return prvKeyRaw;
			}
		}
		
		/***********************************************************************
		 * ECDSA Public Key
		 */
		struct PublicKey
		{
		private:
			import std.typecons: RefCounted, RefCountedAutoInitialize, refCounted;
			struct Instance
			{
				EVP_PKEY* _key;
				@disable this(this);
				~this() @trusted
				{
					if (_key)
						EVP_PKEY_free(_key);
				}
			}
			RefCounted!(Instance, RefCountedAutoInitialize.no) _instance;
			static PublicKey makeInst(EVP_PKEY* key)
			{
				return PublicKey(refCounted(Instance(key)));
			}
			inout(EVP_PKEY)* _key() inout
			{
				return _instance._key;
			}
		public:
			/***********************************************************************
			 * Create new Private Key
			 */
			static PublicKey createKey(PrivateKey prvKey)
			{
				import deimos.openssl.ec;
				auto ecKeyPrv = EVP_PKEY_get1_EC_KEY(cast(EVP_PKEY*)prvKey._key).enforce("Cannot create public key.");
				auto ecGroup = EC_KEY_get0_group(ecKeyPrv).enforce("Cannot create public key.");
				auto prvBn = EC_KEY_get0_private_key(ecKeyPrv).enforce("Cannot create public key.");
				auto pubPt = EC_POINT_new(ecGroup).enforce("Cannot create public key.");
				scope (failure)
					if (pubPt)
						EC_POINT_free(pubPt);
				EC_POINT_mul(ecGroup, pubPt, prvBn, null, null, null).evpEnforce("Cannot create public key.");
				auto ecKeyPub = EC_KEY_new_by_curve_name(curveName).enforce("Cannot create public key.");
				scope (failure)
					if (ecKeyPub)
						EC_KEY_free(ecKeyPub);
				EC_KEY_set_public_key(ecKeyPub, pubPt).evpEnforce("Cannot create public key.");
				pubPt = null;
				
				auto pubKey = EVP_PKEY_new().enforce("Cannot create public key.");
				scope (failure)
					EVP_PKEY_free(pubKey);
				EVP_PKEY_assign_EC_KEY(pubKey, ecKeyPub).evpEnforce("Cannot create public key.");
				ecKeyPub = null;
				return makeInst(pubKey);
			}
			/***********************************************************************
			 * Public Key from PEM string
			 */
			static PublicKey fromPEM(in char[] pubKey)
			{
				import deimos.openssl.bio;
				import deimos.openssl.pem;
				// PEM形式の文字列をBIOメモリストリームに読み込む
				auto bio = BIO_new_mem_buf(cast(void*)pubKey.ptr, cast(int)pubKey.length)
					.enforce("Cannot create specified private key.");
				scope (exit)
					bio.BIO_free();
				return makeInst(PEM_read_bio_PUBKEY(bio, null, null, null));
			}
			/***********************************************************************
			 * Public Key from DER binary
			 */
			static PublicKey fromDER(in ubyte[] pubKey)
			{
				import deimos.openssl.x509;
				// 公開鍵を読み込み
				auto pBuf = pubKey.ptr;
				return makeInst(d2i_PUBKEY(null, &pBuf, cast(int)pubKey.length)
					.enforce("Cannot create specified private key."));
			}
			/***********************************************************************
			 * Public Key from 256bit binary
			 */
			static PublicKey fromBinary(in BinaryKey!pubKeyLen pubKey)
			{
				import deimos.openssl.ec;
				auto eckey = EC_KEY_new_by_curve_name(curveName);
				scope (failure)
					if (eckey)
						EC_KEY_free(eckey);
				auto pBuf = pubKey.ptr;
				o2i_ECPublicKey(&eckey, &pBuf, pubKey.length).enforce("Cannot create specified private key.");
				auto pkey = EVP_PKEY_new();
				scope (failure)
					if (pkey)
						EVP_PKEY_free(pkey);
				EVP_PKEY_assign_EC_KEY(pkey, eckey).evpEnforce("Cannot create specified private key.");
				eckey = null;
				return makeInst(pkey);
			}
			/***********************************************************************
			 * Public Key to PEM string
			 */
			PEMString toPEM() const
			{
				import deimos.openssl.pem;
				// BIOメモリバッファを作成
				auto mem = BIO_new(BIO_s_mem()).enforce("Cannot convert specified private key.");
				scope (exit)
					mem.BIO_free();
				// PEM形式で公開鍵を書き込む
				PEM_write_bio_PUBKEY(mem, cast(EVP_PKEY*)_key).evpEnforce("Cannot convert specified private key.");
				// 文字列の取り出し
				ubyte* pemData = null;
				auto pemLen = BIO_get_mem_data(mem, &pemData);
				auto pemStr = new char[pemLen];
				pemStr[0..pemLen] = cast(char[])pemData[0..pemLen];
				return pemStr.assumeUnique;
			}
			/***********************************************************************
			 * Public Key to DER binary
			 */
			DERBinary toDER() const
			{
				// 公開鍵をDER形式に保存
				import deimos.openssl.x509;
				auto derlen = i2d_PUBKEY(cast(EVP_PKEY*)_key, null).enforce("Cannot create specified private key.");
				auto derPrvKey = new ubyte[derlen];
				auto pBuf = derPrvKey.ptr;
				i2d_PUBKEY(cast(EVP_PKEY*)_key, &pBuf).evpEnforce("Cannot create specified private key.");
				return derPrvKey.assumeUnique;
			}
			/***********************************************************************
			 * Public Key to 256bit binary
			 */
			BinaryKey!pubKeyLen toBinary() const
			{
				import deimos.openssl.ec;
				// EC_KEY 型を取得
				auto ecKey = EVP_PKEY_get1_EC_KEY(cast(EVP_PKEY*)_key).enforce("Cannot export private key.");
				
				// EC_POINT を取得
				auto group = EC_KEY_get0_group(ecKey).enforce("Cannot export private key.");
				auto point = EC_KEY_get0_public_key(ecKey).enforce("Cannot export private key.");
				
				// バイナリ形式に変換
				BinaryKey!pubKeyLen ret;
				enum keyType = point_conversion_form_t.POINT_CONVERSION_UNCOMPRESSED;
				auto len = EC_POINT_point2oct(group, point, keyType, ret.ptr, ret.length, null)
					.enforce("Cannot export private key.");
				assert(len == pubKeyLen);
				return ret;
			}
		}
		
		/***********************************************************************
		 * 署名
		 */
		bin_t sign(in ubyte[] message, in PrivateKey prvKey)
		{
			auto ctxSign = EVP_PKEY_CTX_new(cast(EVP_PKEY*)prvKey._key, null);
			scope (exit)
				ctxSign.EVP_PKEY_CTX_free();
			ctxSign.EVP_PKEY_sign_init()
				.evpEnforce("ECDSA sign failed.");
			
			// 署名のサイズを取得してバッファを作成
			size_t signLen;
			ctxSign.EVP_PKEY_sign(null, &signLen, null, 0)
				.evpEnforce("ECDSA sign failed.");
			auto signData = new ubyte[signLen];
			
			// 署名
			ctxSign.EVP_PKEY_sign(signData.ptr, &signLen, message.ptr, message.length)
				.evpEnforce("ECDSA sign failed.");
			return signData[0..signLen].convECDSASignDer2Bin;
		}
		
		/***********************************************************************
		 * 検証
		 */
		bool verify(in ubyte[] message, in ubyte[] signature, in PublicKey pubKey)
		{
			// 初期化
			auto ctxVerify = EVP_PKEY_CTX_new(cast(EVP_PKEY*)pubKey._key, null);
			scope (exit)
				ctxVerify.EVP_PKEY_CTX_free();
			ctxVerify.EVP_PKEY_verify_init()
				.evpEnforce("ECDSA verify failed.");
			
			// 検証
			auto signDat = signature.convECDSASignBin2Der();
			auto res = ctxVerify.EVP_PKEY_verify(signDat.ptr, signDat.length,
				cast(ubyte*)message.ptr, message.length);
			return res != 0;
		}
	}
	///
	alias OpenSSLECDSAP256Engine = OpenSSLECDSAEngine!(ECDSAType.p256);
	///
	alias OpenSSLECDSAP256KEngine = OpenSSLECDSAEngine!(ECDSAType.p256k);
	///
	alias OpenSSLECDSAP384Engine = OpenSSLECDSAEngine!(ECDSAType.p384);
	///
	alias OpenSSLECDSAP521Engine = OpenSSLECDSAEngine!(ECDSAType.p521);
	
	private struct OpenSSLRSA4096Engine
	{
		struct PrvDat
		{
			ubyte[512] modulus;             // n
			ubyte[4]   publicExponent;      // e
			ubyte[512] privateExponent;     // d
			ubyte[256] prime1;              // p
			ubyte[256] prime2;              // q
			ubyte[256] exponent1;           // d mod (p-1)
			ubyte[256] exponent2;           // d mod (q-1)
			ubyte[256] coefficient;         // q^(-1) mod p
		}
		struct PubDat
		{
			ubyte[512] modulus;             // n
			ubyte[4]   publicExponent;      // e
		}
		enum prvKeyLen = PrvDat.sizeof;
		enum pubKeyLen = PubDat.sizeof;
		/***********************************************************************
		 * RSA4096 Private Key
		 */
		struct PrivateKey
		{
		private:
			import std.typecons: RefCounted, RefCountedAutoInitialize, refCounted;
			struct Instance
			{
				EVP_PKEY* _key;
				@disable this(this);
				~this() @trusted
				{
					if (_key)
						EVP_PKEY_free(_key);
				}
			}
			RefCounted!(Instance, RefCountedAutoInitialize.no) _instance;
			static PrivateKey makeInst(EVP_PKEY* key)
			{
				return PrivateKey(refCounted(Instance(key)));
			}
			inout(EVP_PKEY)* _key() inout
			{
				return _instance._key;
			}
		public:
			/***********************************************************************
			 * Create new Private Key
			 */
			static PrivateKey createKey()
			{
				import deimos.openssl.rsa;
				auto ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, null).enforce("Cannot create private key.");
				scope (exit)
					ctx.EVP_PKEY_CTX_free();
				ctx.EVP_PKEY_keygen_init();
				ctx.EVP_PKEY_CTX_set_rsa_keygen_bits(4096).evpEnforce("Cannot create private key.");
				EVP_PKEY* pkey;
				ctx.EVP_PKEY_keygen(&pkey).evpEnforce("Cannot create private key.");
				return makeInst(pkey);
			}
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PrivateKey fromPEM(in char[] prvKey)
			{
				import deimos.openssl.bio;
				import deimos.openssl.pem;
				// PEM形式の文字列をBIOメモリストリームに読み込む
				auto bio = BIO_new_mem_buf(cast(void*)prvKey.ptr, cast(int)prvKey.length)
					.enforce("Cannot create specified private key.");
				scope (exit)
					bio.BIO_free();
				return makeInst(PEM_read_bio_PrivateKey(bio, null, null, null));
			}
			/***********************************************************************
			 * Private Key from DER binary
			 */
			static PrivateKey fromDER(in ubyte[] prvKey)
			{
				// 秘密鍵を読み込み
				auto pBuf = prvKey.ptr;
				return makeInst(d2i_PrivateKey(EVP_PKEY_RSA, null, &pBuf, cast(int)prvKey.length)
					.enforce("Cannot convert specified private key."));
			}
			/***********************************************************************
			 * Private Key from raw binary
			 */
			static PrivateKey fromBinary(in BinaryKey!prvKeyLen prvKey)
			{
				auto prvKeyDat = cast(PrvDat*)prvKey.ptr;
				auto derseq = cast(immutable(ubyte)[])[0x02, 0x01, 0x00]
					~ encasn1bn(prvKeyDat.modulus[])
					~ encasn1bn(prvKeyDat.publicExponent[])
					~ encasn1bn(prvKeyDat.privateExponent[])
					~ encasn1bn(prvKeyDat.prime1[])
					~ encasn1bn(prvKeyDat.prime2[])
					~ encasn1bn(prvKeyDat.exponent1[])
					~ encasn1bn(prvKeyDat.exponent2[])
					~ encasn1bn(prvKeyDat.coefficient[]);
				return fromDER(encasn1seq(derseq));
			}
			/***********************************************************************
			 * Private Key to PEM string
			 */
			PEMString toPEM() const
			{
				import deimos.openssl.pem;
				// BIOメモリバッファを作成
				auto mem = BIO_new(BIO_s_mem()).enforce("Cannot convert specified private key.");
				scope (exit)
					mem.BIO_free();
				auto rsa = EVP_PKEY_get1_RSA(cast(EVP_PKEY*)_key);
				// PEM形式で秘密鍵を書き込む
				PEM_write_bio_RSAPrivateKey(mem, rsa, null, null, 0, null, null)
					.evpEnforce("Cannot convert specified private key.");
				// 文字列の取り出し
				ubyte* pemData = null;
				auto pemLen = BIO_get_mem_data(mem, &pemData);
				auto pemStr = new char[pemLen];
				pemStr[0..pemLen] = cast(char[])pemData[0..pemLen];
				return pemStr.assumeUnique;
			}
			/***********************************************************************
			 * Private Key to DER binary
			 */
			DERBinary toDER() const
			{
				// 公開鍵をDER形式に保存
				auto derlen = i2d_PrivateKey(cast(EVP_PKEY*)_key, null).enforce("Cannot create specified private key.");
				auto derPrvKey = new ubyte[derlen];
				auto pBuf = derPrvKey.ptr;
				i2d_PrivateKey(cast(EVP_PKEY*)_key, &pBuf).evpEnforce("Cannot create specified private key.");
				return derPrvKey.assumeUnique;
			}
			/***********************************************************************
			 * Private Key to raw binary
			 */
			BinaryKey!prvKeyLen toBinary() const
			{
				ubyte[prvKeyLen] ret;
				auto dat = cast(PrvDat*)ret.ptr;
				const(ubyte)[] derall = toDER();
				auto der = decasn1seq(derall);
				auto ver = decasn1bn(der);
				enforce(ver.length == 1 && ver[0] == 0x00, "Invalid private key format.");
				dat.modulus[0..512]         = decasn1bn(der, 512)[0..512];
				dat.publicExponent[0..4]    = decasn1bn(der, 4)[0..4];
				dat.privateExponent[0..512] = decasn1bn(der, 512)[0..512];
				dat.prime1[0..256]          = decasn1bn(der, 256)[0..256];
				dat.prime2[0..256]          = decasn1bn(der, 256)[0..256];
				dat.exponent1[0..256]       = decasn1bn(der, 256)[0..256];
				dat.exponent2[0..256]       = decasn1bn(der, 256)[0..256];
				dat.coefficient[0..256]     = decasn1bn(der, 256)[0..256];
				return ret;
			}
		}
		/***********************************************************************
		 * RSA4096 Public Key
		 */
		struct PublicKey
		{
		private:
			import std.typecons: RefCounted, RefCountedAutoInitialize, refCounted;
			struct Instance
			{
				EVP_PKEY* _key;
				@disable this(this);
				~this() @trusted
				{
					if (_key)
						EVP_PKEY_free(_key);
				}
			}
			RefCounted!(Instance, RefCountedAutoInitialize.no) _instance;
			static PublicKey makeInst(EVP_PKEY* key)
			{
				return PublicKey(refCounted(Instance(key)));
			}
			inout(EVP_PKEY)* _key() inout
			{
				return _instance._key;
			}
		public:
			/***********************************************************************
			 * Create new Public Key
			 */
			static PublicKey createKey(PrivateKey prvKey)
			{
				import deimos.openssl.x509;
				auto derlen = i2d_PUBKEY(cast(EVP_PKEY*)prvKey._key, null).enforce("Cannot create specified private key.");
				auto derPubKey = new ubyte[derlen];
				auto pBuf = derPubKey.ptr;
				i2d_PUBKEY(cast(EVP_PKEY*)prvKey._key, &pBuf).evpEnforce("Cannot create specified private key.");
				return fromDER(derPubKey);
			}
			/***********************************************************************
			 * Public Key from PEM string
			 */
			static PublicKey fromPEM(in char[] pubKey)
			{
				import deimos.openssl.bio;
				import deimos.openssl.pem;
				// PEM形式の文字列をBIOメモリストリームに読み込む
				auto bio = BIO_new_mem_buf(cast(void*)pubKey.ptr, cast(int)pubKey.length)
					.enforce("Cannot create specified private key.");
				scope (exit)
					bio.BIO_free();
				return makeInst(PEM_read_bio_PUBKEY(bio, null, null, null));
			}
			/***********************************************************************
			 * Public Key from DER binary
			 */
			static PublicKey fromDER(in ubyte[] pubKey)
			{
				import deimos.openssl.x509;
				// 公開鍵を読み込み
				auto pBuf = pubKey.ptr;
				return makeInst(d2i_PUBKEY(null, &pBuf, cast(int)pubKey.length)
					.enforce("Cannot convert specified private key."));
			}
			/***********************************************************************
			 * Public Key from raw binary
			 */
			static PublicKey fromBinary(in BinaryKey!pubKeyLen pubKey)
			{
				auto pubKeyDat = cast(PrvDat*)pubKey.ptr;
				return fromDER(encasn1seq(
					encasn1seq(cast(ubyte[])[0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
					~ encasn1str(encasn1seq(
						encasn1bn(pubKeyDat.modulus[])
						~ encasn1bn(pubKeyDat.publicExponent[])))));
			}
			/***********************************************************************
			 * Public Key to PEM string
			 */
			PEMString toPEM() const
			{
				import deimos.openssl.pem;
				// BIOメモリバッファを作成
				auto mem = BIO_new(BIO_s_mem()).enforce("Cannot convert specified private key.");
				scope (exit)
					mem.BIO_free();
				// PEM形式で公開鍵を書き込む
				PEM_write_bio_PUBKEY(mem, cast(EVP_PKEY*)_key).evpEnforce("Cannot convert specified private key.");
				// 文字列の取り出し
				ubyte* pemData = null;
				auto pemLen = BIO_get_mem_data(mem, &pemData);
				auto pemStr = new char[pemLen];
				pemStr[0..pemLen] = cast(char[])pemData[0..pemLen];
				return pemStr.assumeUnique;
			}
			/***********************************************************************
			 * Public Key to DER binary
			 */
			DERBinary toDER() const
			{
				// 公開鍵をDER形式に保存
				import deimos.openssl.x509;
				auto derlen = i2d_PUBKEY(cast(EVP_PKEY*)_key, null).enforce("Cannot create specified private key.");
				auto derPubKey = new ubyte[derlen];
				auto pBuf = derPubKey.ptr;
				i2d_PUBKEY(cast(EVP_PKEY*)_key, &pBuf).evpEnforce("Cannot create specified private key.");
				return derPubKey.assumeUnique;
			}
			/***********************************************************************
			 * Public Key to raw binary
			 */
			BinaryKey!pubKeyLen toBinary() const
			{
				ubyte[pubKeyLen] ret;
				auto dat = cast(PubDat*)ret.ptr;
				const(ubyte)[] derall = toDER();
				auto derseq = decasn1seq(derall);
				auto objId  = decasn1seq(derseq);
				auto contentStr  = decasn1str(derseq);
				auto pubKeyDat   = decasn1seq(contentStr);
				dat.modulus[0..512]      = decasn1bn(pubKeyDat, 512)[0..512];
				dat.publicExponent[0..4] = decasn1bn(pubKeyDat, 4)[0..4];
				return ret;
			}
		}
		/***********************************************************************
		 * 署名
		 */
		bin_t sign(in ubyte[] message, PrivateKey prvKey)
		{
			import deimos.openssl.rsa;
			// 初期化
			auto ctxSign = EVP_PKEY_CTX_new(cast(EVP_PKEY*)prvKey._key, null);
			scope (exit)
				ctxSign.EVP_PKEY_CTX_free();
			ctxSign.EVP_PKEY_sign_init()
				.evpEnforce("RSA 4096 sign failed.");
			// 署名のサイズを取得してバッファを作成
			size_t signLen;
			ctxSign.EVP_PKEY_sign(null, &signLen, null, 0);
			auto signData = new ubyte[signLen];
			
			// 署名
			ctxSign.EVP_PKEY_sign(signData.ptr, &signLen, message.ptr, message.length)
				.evpEnforce("RSA 4096 sign failed.");
			return signData[0..signLen].assumeUnique;
		}
		/***********************************************************************
		 * 検証
		 */
		bool verify(in ubyte[] message, in ubyte[] signature, PublicKey pubKey)
		{
			// 初期化
			auto ctxVerify = EVP_PKEY_CTX_new(cast(EVP_PKEY*)pubKey._key, null);
			scope (exit)
				ctxVerify.EVP_PKEY_CTX_free();
			ctxVerify.EVP_PKEY_verify_init()
				.evpEnforce("RSA 4096 verify failed.");
			
			// 検証
			auto ret = ctxVerify.EVP_PKEY_verify(signature.ptr, signature.length,
				cast(ubyte*)message.ptr, message.length);
			return ret != 0;
		}
		/***********************************************************************
		 * 暗号化
		 */
		bin_t encrypt(in ubyte[] data, PublicKey pubKey)
		{
			// 初期化
			auto ctxEnc = EVP_PKEY_CTX_new(pubKey._key, null);
			scope (exit)
				ctxEnc.EVP_PKEY_CTX_free();
			ctxEnc.EVP_PKEY_encrypt_init().evpEnforce("RSA 4096 encrypt failed.");
			
			// バッファ長取得
			size_t len;
			ctxEnc.EVP_PKEY_encrypt(null, &len, data.ptr, data.length).evpEnforce("RSA 4096 encrypt failed.");
			// 暗号化
			auto buf = new ubyte[len];
			ctxEnc.EVP_PKEY_encrypt(buf.ptr, &len, data.ptr, data.length).evpEnforce("RSA 4096 encrypt failed.");
			return buf[0..len].assumeUnique();
		}
		/***********************************************************************
		 * 復号
		 */
		bin_t decrypt(in ubyte[] data, PrivateKey prvKey)
		{
			// 初期化
			auto ctxDec = EVP_PKEY_CTX_new(prvKey._key, null);
			scope (exit)
				ctxDec.EVP_PKEY_CTX_free();
			ctxDec.EVP_PKEY_decrypt_init().evpEnforce("RSA 4096 encrypt failed.");
			
			// バッファ長取得
			size_t len;
			ctxDec.EVP_PKEY_decrypt(null, &len, data.ptr, data.length).evpEnforce("RSA 4096 encrypt failed.");
			// 暗号化
			auto buf = new ubyte[len];
			ctxDec.EVP_PKEY_decrypt(buf.ptr, &len, data.ptr, data.length).evpEnforce("RSA 4096 encrypt failed.");
			return buf[0..len].assumeUnique();
		}
	}
	
	private struct OpenSSLECDHP256Engine
	{
		enum prvKeyLen = 32;
		enum pubKeyLen = 65;
		alias PrivateKey = OpenSSLECDSAP256Engine.PrivateKey;
		alias PublicKey  = OpenSSLECDSAP256Engine.PublicKey;
	public:
		/***********************************************************************
		 * Derive shared secret
		 */
		bin_t derive(in PrivateKey prvKey, in PublicKey pubKey)
		{
			auto ctx = EVP_PKEY_CTX_new(cast(EVP_PKEY*)prvKey._key, null);
			ctx.EVP_PKEY_derive_init().evpEnforce("Cannot derive shared secret.");
			ctx.EVP_PKEY_derive_set_peer(cast(EVP_PKEY*)pubKey._key).evpEnforce("Cannot derive shared secret.");
			size_t len = 32;
			auto buf = new ubyte[len];
			ctx.EVP_PKEY_derive(buf.ptr, &len).evpEnforce("Cannot derive shared secret.");
			assert(len == 32);
			return buf[0..len].assumeUnique;
		}
	}
}

//##############################################################################
//##### Windows Bcrypt Engines
//##############################################################################
static if (enableBcryptEngines)
{
	private extern (Windows)
	{
		import core.sys.windows.windows;
		pragma(lib, "Bcrypt");
		pragma(lib, "User32");
		alias BCRYPT_HANDLE = void*;
		alias BCRYPT_ALG_HANDLE = BCRYPT_HANDLE;
		alias BCRYPT_KEY_HANDLE = BCRYPT_HANDLE;
		alias BCRYPT_SECRET_HANDLE = BCRYPT_HANDLE;
		alias NTSTATUS = int;
		NTSTATUS BCryptOpenAlgorithmProvider(BCRYPT_ALG_HANDLE* phAlgorithm, LPCWSTR pszAlgId,
			LPCWSTR pszImplementation, ULONG dwFlags);
		NTSTATUS BCryptSetProperty(BCRYPT_HANDLE hObject, LPCWSTR pszProperty,
			PUCHAR pbInput, ULONG cbInput, ULONG dwFlags);
		NTSTATUS BCryptGetProperty(BCRYPT_HANDLE hObject, LPCWSTR pszProperty,
			PUCHAR pbOutput, ULONG cbOutput, ULONG* pcbResult, ULONG dwFlags);
		NTSTATUS BCryptGenerateKeyPair(BCRYPT_ALG_HANDLE hAlgorithm, BCRYPT_KEY_HANDLE* phKey, ULONG dwLength,
			ULONG dwFlags);
		NTSTATUS BCryptGenerateSymmetricKey(BCRYPT_ALG_HANDLE hAlgorithm, BCRYPT_KEY_HANDLE* phKey, PUCHAR pbKeyObject,
			ULONG cbKeyObject, PUCHAR pbSecret, ULONG cbSecret, ULONG dwFlags);
		NTSTATUS BCryptDestroyKey(BCRYPT_KEY_HANDLE hKey);
		NTSTATUS BCryptCloseAlgorithmProvider(BCRYPT_ALG_HANDLE hAlgorithm, ULONG dwFlags);
		NTSTATUS BCryptEncrypt(BCRYPT_KEY_HANDLE hKey, PUCHAR pbInput, ULONG cbInput, VOID* pPaddingInfo,
			PUCHAR pbIV, ULONG cbIV, PUCHAR pbOutput, ULONG cbOutput, ULONG* pcbResult, ULONG dwFlags);
		NTSTATUS BCryptDecrypt(BCRYPT_KEY_HANDLE hKey, PUCHAR pbInput, ULONG cbInput, VOID* pPaddingInfo,
			PUCHAR pbIV, ULONG cbIV, PUCHAR pbOutput, ULONG cbOutput, ULONG* pcbResult, ULONG dwFlags);
		NTSTATUS BCryptImportKeyPair(BCRYPT_ALG_HANDLE hAlgorithm, BCRYPT_KEY_HANDLE hImportKey, LPCWSTR pszBlobType,
			BCRYPT_KEY_HANDLE* phKey, PUCHAR pbInput, ULONG cbInput, ULONG dwFlags);
		NTSTATUS BCryptImportKey(BCRYPT_ALG_HANDLE hAlgorithm, BCRYPT_KEY_HANDLE hImportKey, LPCWSTR pszBlobType,
			BCRYPT_KEY_HANDLE* phKey, PUCHAR pbKeyObject, ULONG cbKeyObject, PUCHAR pbInput, ULONG cbInput,
			ULONG dwFlags);
		NTSTATUS BCryptExportKey(BCRYPT_KEY_HANDLE hKey, BCRYPT_KEY_HANDLE hExportKey, LPCWSTR pszBlobType,
			PUCHAR pbOutput, ULONG cbOutput, ULONG* pcbResult, ULONG dwFlags);
		NTSTATUS BCryptFinalizeKeyPair(BCRYPT_KEY_HANDLE hKey, ULONG dwFlags);
		NTSTATUS BCryptSignHash(BCRYPT_KEY_HANDLE hKey, VOID* pPaddingInfo, PUCHAR pbInput, ULONG cbInput,
			PUCHAR pbOutput, ULONG cbOutput, ULONG* pcbResult, ULONG dwFlags);
		NTSTATUS BCryptVerifySignature(BCRYPT_KEY_HANDLE hKey, VOID* pPaddingInfo, PUCHAR pbHash, ULONG cbHash,
			PUCHAR pbSignature, ULONG cbSignature, ULONG dwFlags);
		NTSTATUS BCryptSecretAgreement(BCRYPT_KEY_HANDLE hPrivKey, BCRYPT_KEY_HANDLE hPubKey,
			BCRYPT_SECRET_HANDLE* phAgreedSecret, ULONG dwFlags);
		NTSTATUS BCryptDestroySecret(BCRYPT_SECRET_HANDLE hSecret);
		NTSTATUS BCryptDeriveKey(BCRYPT_SECRET_HANDLE hSharedSecret, LPCWSTR pwszKDF, void* pParameterList,
			PUCHAR pbDerivedKey, ULONG cbDerivedKey, ULONG* pcbResult, ULONG dwFlags);
		enum ULONG BCRYPT_RSAPUBLIC_MAGIC =             0x31415352; // RSA1
		enum ULONG BCRYPT_RSAPRIVATE_MAGIC =            0x32415352; // RSA2
		enum ULONG BCRYPT_RSAFULLPRIVATE_MAGIC =        0x33415352; // RSA3
		enum ULONG BCRYPT_ECDH_PUBLIC_P256_MAGIC =      0x314B4345; // ECK1
		enum ULONG BCRYPT_ECDH_PRIVATE_P256_MAGIC =     0x324B4345; // ECK2
		enum ULONG BCRYPT_ECDH_PUBLIC_P384_MAGIC =      0x334B4345; // ECK3
		enum ULONG BCRYPT_ECDH_PRIVATE_P384_MAGIC =     0x344B4345; // ECK4
		enum ULONG BCRYPT_ECDH_PUBLIC_P521_MAGIC =      0x354B4345; // ECK5
		enum ULONG BCRYPT_ECDH_PRIVATE_P521_MAGIC =     0x364B4345; // ECK6
		enum ULONG BCRYPT_ECDSA_PUBLIC_P256_MAGIC =     0x31534345; // ECS1
		enum ULONG BCRYPT_ECDSA_PRIVATE_P256_MAGIC =    0x32534345; // ECS2
		enum ULONG BCRYPT_ECDSA_PUBLIC_P384_MAGIC =     0x33534345; // ECS3
		enum ULONG BCRYPT_ECDSA_PRIVATE_P384_MAGIC =    0x34534345; // ECS4
		enum ULONG BCRYPT_ECDSA_PUBLIC_P521_MAGIC =     0x35534345; // ECS5
		enum ULONG BCRYPT_ECDSA_PRIVATE_P521_MAGIC =    0x36534345; // ECS6
		enum ULONG BCRYPT_ECDH_PUBLIC_GENERIC_MAGIC =   0x504B4345; // ECKP
		enum ULONG BCRYPT_ECDH_PRIVATE_GENERIC_MAGIC =  0x564B4345; // ECKV
		enum ULONG BCRYPT_ECDSA_PUBLIC_GENERIC_MAGIC =  0x50444345; // ECDP
		enum ULONG BCRYPT_ECDSA_PRIVATE_GENERIC_MAGIC = 0x56444345; // ECDP
		enum ULONG BCRYPT_NO_KEY_VALIDATION = 0x00000008;
		bool ntEnforce(NTSTATUS status, string message, string f = __FILE__, size_t l = __LINE__)
		{
			return enforce(status >= 0, message, f, l);
		}
		
	}
	///
	private struct BcryptAESCBCEncryptEngine
	{
	private:
		BCRYPT_ALG_HANDLE _hAlg;
		BCRYPT_KEY_HANDLE _hKey;
		ubyte[16] _iv;
		ubyte[16] _remain;
		ubyte     _remainNum;
	public:
		/***********************************************************************
		 * Constructor
		 */
		this(in ubyte[] key, in ubyte[] iv) @trusted
		{
			_hAlg = BCRYPT_ALG_HANDLE.init;
			_hKey = BCRYPT_KEY_HANDLE.init;
			_iv[] = iv[0..16];
			
			BCryptOpenAlgorithmProvider(&_hAlg, "AES", null, 0).ntEnforce("Cannot open algorithm provider.");
			
			BCryptGenerateSymmetricKey(_hAlg, &_hKey, null, 0, cast(ubyte*)key.ptr, cast(ULONG)key.length, 0)
				.ntEnforce("Cannot generate symmetric key.");
		}
		/***********************************************************************
		 * Destructor
		 */
		~this() @trusted
		{
			if (_hKey)
				cast(void)BCryptDestroyKey(_hKey);
			if (_hAlg)
				cast(void)BCryptCloseAlgorithmProvider(_hAlg, 0);
		}
		/***********************************************************************
		 * Update
		 */
		void update(OutputRange)(in ubyte[] data, ref OutputRange dst)
		if (isOutputRange!(OutputRange, ubyte))
		{
			import core.stdc.stdlib: malloc, free;
			const(ubyte)[] src;
			if (_remainNum != 0)
			{
				ubyte[16] outData;
				ULONG outLen = 0;
				if (data.length < _remain.length - _remainNum)
				{
					_remain[_remainNum .. _remainNum + data.length] = data[];
					_remainNum += cast(ubyte)data.length;
					return;
				}
				_remain[_remainNum .. $] = data[0 .. _remain.length - _remainNum];
				src = data[_remain.length - _remainNum .. $];
				BCryptEncrypt(_hKey, cast(ubyte*)_remain.ptr, cast(ULONG)16, null, _iv.ptr, _iv.length,
					outData.ptr, cast(ULONG)16, &outLen, 0)
					.ntEnforce("Bcrypt AES encryption failed.");
				dst.put(outData[]);
			}
			else
			{
				src = data[];
			}
			
			_remainNum = cast(ubyte)(src.length % 16);
			_remain[0 .. _remainNum] = src[$ - _remainNum .. $];
			src = src[0 .. $ - _remainNum];
			
			if (src.length == 0)
				return;
			
			auto outData = cast(ubyte*)malloc(src.length);
			scope (exit)
				outData.free();
			
			ULONG outLen = 0;
			BCryptEncrypt(_hKey, cast(ubyte*)src.ptr, cast(ULONG)src.length, null, _iv.ptr, _iv.length,
				outData, cast(ULONG)src.length, &outLen, 0)
				.ntEnforce("Bcrypt AES encryption failed.");
			
			dst.put(outData[0 .. cast(size_t)outLen]);
		}
		
		/***********************************************************************
		 * Finalize
		 */
		void finalize(OutputRange)(ref OutputRange dst, bool padding = true)
		if (isOutputRange!(OutputRange, ubyte))
		{
			if (!padding)
				return;
			_remain[_remainNum .. $] = cast(ubyte)(16 - _remainNum);
			ubyte[16] outData;
			ULONG outLen = 0;
			BCryptEncrypt(_hKey, cast(ubyte*)_remain.ptr, cast(ULONG)16, null, _iv.ptr, _iv.length,
				outData.ptr, cast(ULONG)16, &outLen, 0)
				.ntEnforce("Bcrypt AES encryption failed.");
			dst.put(outData[]);
		}
	}
	///
	alias BcryptAES128CBCEncryptEngine = BcryptAESCBCEncryptEngine;
	///
	alias BcryptAES192CBCEncryptEngine = BcryptAESCBCEncryptEngine;
	///
	alias BcryptAES256CBCEncryptEngine = BcryptAESCBCEncryptEngine;
	///
	private struct BcryptAESCBCDecryptEngine
	{
	private:
		import core.sys.windows.windows;
		BCRYPT_ALG_HANDLE _hAlg;
		BCRYPT_KEY_HANDLE _hKey;
		ubyte[16] _iv;
		ubyte[16] _remain;
		ubyte     _remainNum;
		ubyte[16] _prev;
		ubyte     _prevNum;
	public:
		/***********************************************************************
		 * Constructor
		 */
		this(in ubyte[] key, in ubyte[] iv)
		{
			_iv[] = iv[0..16];
			BCryptOpenAlgorithmProvider(&_hAlg, "AES", null, 0).ntEnforce("Cannot open algorithm provider.");
			BCryptGenerateSymmetricKey(_hAlg, &_hKey, null, 0, cast(ubyte*)key.ptr, cast(ULONG)key.length, 0)
				.ntEnforce("Cannot generate symmetric key.");
		}
		/***********************************************************************
		 * Destructor
		 */
		~this() @trusted
		{
			if (_hKey)
				cast(void)BCryptDestroyKey(_hKey);
			if (_hAlg)
				cast(void)BCryptCloseAlgorithmProvider(_hAlg, 0);
		}
		/***********************************************************************
		 * Update
		 */
		void update(OutputRange)(in ubyte[] data, ref OutputRange dst)
		if (isOutputRange!(OutputRange, ubyte))
		{
			import core.stdc.stdlib: malloc, free;
			
			const(ubyte)[] src;
			if (_remainNum != 0)
			{
				if (data.length < _remain.length - _remainNum)
				{
					_remain[_remainNum .. _remainNum + data.length] = data[];
					_remainNum += cast(ubyte)data.length;
					return;
				}
				_remain[_remainNum .. $] = data[0 .. _remain.length - _remainNum];
				src = data[_remain.length - _remainNum .. $];
				
				if (_prevNum != 0)
				{
					dst.put(_prev[0 .. _prevNum]);
					_prevNum = 0;
				}
				ubyte[16] outData;
				ULONG outLen = 0;
				
				BCryptDecrypt(_hKey, cast(ubyte*)_remain.ptr, cast(ULONG)16, null, _iv.ptr, _iv.length,
					outData.ptr, cast(ULONG)16, &outLen, 0)
					.ntEnforce("Bcrypt AES decryption failed.");
				_prev[] = outData[];
				_prevNum = 16;
			}
			else
			{
				src = data[];
			}
			
			_remainNum = cast(ubyte)(src.length % 16);
			_remain[0 .. _remainNum] = src[$ - _remainNum .. $];
			src = src[0..$ - _remainNum];
			
			if (src.length == 0)
				return;
			assert(src.length % 16 == 0);
			if (_prevNum != 0)
			{
				dst.put(_prev[0 .. _prevNum]);
				_prevNum = 0;
			}
			
			auto outData = cast(ubyte*)malloc(src.length);
			scope (exit)
				outData.free();
			ULONG outLen = 0;
			BCryptDecrypt(_hKey, cast(ubyte*)src.ptr, cast(ULONG)src.length, null, _iv.ptr, cast(ULONG)_iv.length,
				outData, cast(ULONG)src.length, &outLen, 0)
				.ntEnforce("Bcrypt AES decryption failed.");
			if (outLen > 16)
			{
				assert(outLen % 16 == 0);
				dst.put(outData[0 .. cast(size_t)outLen - 16]);
				_prev[] = outData[outLen - 16 .. outLen];
				_prevNum = 16;
			}
			else
			{
				assert(outLen == 16);
				_prev[] = outData[0 .. 16];
				_prevNum = 16;
			}
			
		}
		/***********************************************************************
		 * Finalize
		 */
		void finalize(OutputRange)(ref OutputRange dst, bool padding = true)
		if (isOutputRange!(OutputRange, ubyte))
		{
			if (!padding)
			{
				if (_prevNum != 0)
				{
					dst.put(_prev[0 .. _prevNum]);
					_prevNum = 0;
				}
				return;
			}
			if (_prevNum != 0)
			{
				_prevNum = 0;
				enforce(_prev[$-1] < 16, "Invalid padding.");
				auto padNum = _prev[$-1];
				dst.put(_prev[0 .. $-padNum]);
			}
		}
	}
	///
	alias BcryptAES128CBCDecryptEngine = BcryptAESCBCDecryptEngine;
	///
	alias BcryptAES192CBCDecryptEngine = BcryptAESCBCDecryptEngine;
	///
	alias BcryptAES256CBCDecryptEngine = BcryptAESCBCDecryptEngine;
	///
	private struct BcryptECDSAEngine(ECDSAType type)
	{
		enum ECDSAType cipherType = type;
		enum size_t cntBits = type == ECDSAType.p256 ? 256
			: type == ECDSAType.p256k ? 256
			: type == ECDSAType.p384 ? 384
			: type == ECDSAType.p521 ? 521
			: 32;
		enum size_t prvKeyLen = type == ECDSAType.p256 ? 32
			: type == ECDSAType.p256k ? 32
			: type == ECDSAType.p384 ? 48
			: type == ECDSAType.p521 ? 66
			: 32;
		enum size_t pubKeyLen = type == ECDSAType.p256 ? 65
			: type == ECDSAType.p256k ? 65
			: type == ECDSAType.p384 ? 97
			: type == ECDSAType.p521 ? 133
			: 65;
		private enum algorithmName = type == ECDSAType.p256 ? "ECDSA_P256"
			: type == ECDSAType.p256k ? "ECDSA"
			: type == ECDSAType.p384 ? "ECDSA_P384"
			: type == ECDSAType.p521 ? "ECDSA_P521"
			: "ECDSA_P256";
		private enum prvKeyMagicValue = type == ECDSAType.p256 ? BCRYPT_ECDSA_PRIVATE_P256_MAGIC
			: type == ECDSAType.p256k ? BCRYPT_ECDSA_PRIVATE_GENERIC_MAGIC
			: type == ECDSAType.p384 ? BCRYPT_ECDSA_PRIVATE_P384_MAGIC
			: type == ECDSAType.p521 ? BCRYPT_ECDSA_PRIVATE_P521_MAGIC
			: BCRYPT_ECDSA_PRIVATE_P256_MAGIC;
		private enum pubKeyMagicValue = type == ECDSAType.p256 ? BCRYPT_ECDSA_PUBLIC_P256_MAGIC
			: type == ECDSAType.p256k ? BCRYPT_ECDSA_PUBLIC_GENERIC_MAGIC
			: type == ECDSAType.p384 ? BCRYPT_ECDSA_PUBLIC_P384_MAGIC
			: type == ECDSAType.p521 ? BCRYPT_ECDSA_PUBLIC_P521_MAGIC
			: BCRYPT_ECDSA_PUBLIC_P256_MAGIC;
		private static void setCurveParameters(BCRYPT_ALG_HANDLE hAlg)
		{
			static if (type == ECDSAType.p256k)
			{
				static immutable ubyte[] eccParameters = x"".bin
					~ x"01000000".bin // BCRYPT_ECC_PARAMETERS_V1
					~ x"01000000".bin // BCRYPT_ECC_PRIME_CURVE
					~ x"00000000".bin // dwCurveGenerationAlgId = 0: Custom
					~ x"20000000".bin // cbFieldLength = 32
					~ x"20000000".bin // cbSubgroupOrder = 32
					~ x"01000000".bin // cbCofactor = 1
					~ x"00000000".bin // seed = 0
					~ x"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F".bin // Prime
					~ x"0000000000000000000000000000000000000000000000000000000000000000".bin // A
					~ x"0000000000000000000000000000000000000000000000000000000000000007".bin // B
					~ x"79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798".bin // x
					~ x"483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8".bin // y
					~ x"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141".bin // n
					~ x"01".bin;
				BCryptSetProperty(hAlg, "ECCParameters", cast(PUCHAR)eccParameters.ptr, eccParameters.length, 0)
					.ntEnforce("Cannot setup crypto.");
			}
		}
		
		struct PrivateKey
		{
		private:
			import std.typecons: RefCounted, RefCountedAutoInitialize, refCounted;
			struct Instance
			{
				BCRYPT_ALG_HANDLE _hAlg;
				BCRYPT_KEY_HANDLE _hKey;
				@disable this(this);
				~this() @trusted
				{
					if (_hKey)
						cast(void)BCryptDestroyKey(_hKey);
					if (_hAlg)
						cast(void)BCryptCloseAlgorithmProvider(_hAlg, 0);
				}
			}
			RefCounted!(Instance, RefCountedAutoInitialize.no) _instance;
			static PrivateKey makeInst(BCRYPT_ALG_HANDLE alg, BCRYPT_KEY_HANDLE key)
			{
				return PrivateKey(refCounted(Instance(alg, key)));
			}
			BCRYPT_ALG_HANDLE _alg() inout
			{
				return cast(BCRYPT_ALG_HANDLE)_instance._hAlg;
			}
			BCRYPT_KEY_HANDLE _key() inout
			{
				return cast(BCRYPT_KEY_HANDLE)_instance._hKey;
			}
		public:
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PrivateKey createKey()
			{
				BCRYPT_ALG_HANDLE hAlg;
				BCRYPT_KEY_HANDLE hKey;
				BCryptOpenAlgorithmProvider(&hAlg, algorithmName, null, 0)
					.ntEnforce("Cannot create private key.");
				scope (failure)
					cast(void)BCryptCloseAlgorithmProvider(hAlg, 0);
				setCurveParameters(hAlg);
				BCryptGenerateKeyPair(hAlg, &hKey, cntBits, 0)
					.ntEnforce("Cannot create private key.");
				BCryptFinalizeKeyPair(hKey, 0)
					.ntEnforce("Cannot create private key.");
				return makeInst(hAlg, hKey);
			}
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PrivateKey fromPEM(in char[] prvKey)
			{
				return fromDER(pem2der(prvKey));
			}
			/***********************************************************************
			 * Private Key from DER binary
			 */
			static PrivateKey fromDER(in ubyte[] prvKey)
			{
				const(ubyte)[] der = prvKey[];
				auto seq = decasn1seq(der);
				auto ver = decasn1bn(seq);
				auto prvKeyData = decasn1ostr(seq);
				enforce(prvKeyData.length == prvKeyLen, "Unsupported DER format.");
				return fromBinary(prvKeyData[0..prvKeyLen]);
			}
			/***********************************************************************
			 * Private Key from 256bit binary
			 */
			static PrivateKey fromBinary(in BinaryKey!prvKeyLen prvKey)
			{
				BCRYPT_ALG_HANDLE hAlg;
				BCRYPT_KEY_HANDLE hKey;
				BCryptOpenAlgorithmProvider(&hAlg, algorithmName, null, 0)
					.ntEnforce("Cannot create private key.");
				scope (failure)
					cast(void)BCryptCloseAlgorithmProvider(hAlg, 0);
				setCurveParameters(hAlg);
				struct BcryptKeyPair
				{
				align(1):
					ULONG dwMagic;
					ULONG cbKey;
					BYTE[pubKeyLen-1] XY; // Public Key
					BYTE[prvKeyLen] d;  // Private Key
				}
				BcryptKeyPair keyPair;
				keyPair.dwMagic = prvKeyMagicValue;
				keyPair.cbKey = prvKeyLen;
				keyPair.XY[] = 0;
				keyPair.d[] = prvKey[];
				BCryptImportKeyPair(hAlg, null, "ECCPRIVATEBLOB", &hKey, cast(ubyte*)&keyPair, keyPair.sizeof,
					BCRYPT_NO_KEY_VALIDATION)
					.ntEnforce("Cannot create private key.");
				return makeInst(hAlg, hKey);
			}
			/***********************************************************************
			 * Private Key to PEM string
			 */
			PEMString toPEM() const
			{
				return toDER().der2pem("EC PRIVATE KEY");
			}
			/***********************************************************************
			 * Private Key to DER binary
			 */
			DERBinary toDER() const
			{
				struct BcryptKeyPair
				{
				align(1):
					ULONG dwMagic;
					ULONG cbKey;
					BYTE[pubKeyLen-1] XY; // Public Key
					BYTE[prvKeyLen] d;  // Private key
				}
				BcryptKeyPair keyPair;
				keyPair.dwMagic = prvKeyMagicValue;
				keyPair.cbKey = prvKeyLen;
				ULONG res;
				BCryptExportKey(_key, null, "ECCPRIVATEBLOB", cast(ubyte*)&keyPair, keyPair.sizeof, &res, 0)
					.ntEnforce("Cannot export private key.");
				return encasn1seq(                                              // SEQUENCE
					[0x02, 0x01, 0x01].bin                                      //   INTEGER  VERSION(1)
					~ encasn1ostr(keyPair.d[])                                  //   OCTET STRING (Private Key)
					~ encasn1(0xA0, encasn1(0x06, getOid!type))                 //   [0] EC PARAMETERS: OID
					~ encasn1(0xA1, encasn1str([0x04].bin ~ keyPair.XY[])));    //   [1] EC PUBLIC: BIT STRING (Public Key)
			}
			/***********************************************************************
			 * Private Key to 256bit binary
			 */
			BinaryKey!prvKeyLen toBinary() const
			{
				struct BcryptKeyPair
				{
				align(1):
					ULONG dwMagic;
					ULONG cbKey;
					BYTE[pubKeyLen-1] XY; // Public Key
					BYTE[prvKeyLen] d;    // Private key
				}
				BcryptKeyPair keyPair;
				keyPair.dwMagic = prvKeyMagicValue;
				keyPair.cbKey = prvKeyLen;
				ULONG res;
				BCryptExportKey(_key, null, "ECCPRIVATEBLOB", cast(ubyte*)&keyPair, keyPair.sizeof, &res, 0)
					.ntEnforce("Cannot export private key.");
				assert(res == keyPair.sizeof);
				return keyPair.d[0..prvKeyLen];
			}
		}
		struct PublicKey
		{
		private:
			import std.typecons: RefCounted, RefCountedAutoInitialize, refCounted;
			struct Instance
			{
				BCRYPT_ALG_HANDLE _hAlg;
				BCRYPT_KEY_HANDLE _hKey;
				@disable this(this);
				~this() @trusted
				{
					if (_hKey)
						cast(void)BCryptDestroyKey(_hKey);
					if (_hAlg)
						cast(void)BCryptCloseAlgorithmProvider(_hAlg, 0);
				}
			}
			RefCounted!(Instance, RefCountedAutoInitialize.no) _instance;
			static PublicKey makeInst(BCRYPT_ALG_HANDLE alg, BCRYPT_KEY_HANDLE key)
			{
				return PublicKey(refCounted(Instance(alg, key)));
			}
			BCRYPT_ALG_HANDLE _alg() inout
			{
				return cast(BCRYPT_ALG_HANDLE)_instance._hAlg;
			}
			BCRYPT_KEY_HANDLE _key() inout
			{
				return cast(BCRYPT_KEY_HANDLE)_instance._hKey;
			}
		public:
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PublicKey createKey(PrivateKey prvKey)
			{
				struct KeyBlob
				{
				align(1):
					ULONG dwMagic;
					ULONG cbKey;
					BYTE[pubKeyLen-1] XY; // Public Key
				}
				KeyBlob keyBlob;
				keyBlob.dwMagic = pubKeyMagicValue;
				keyBlob.cbKey = (pubKeyLen-1)/2;
				ULONG res;
				BCryptExportKey(prvKey._key, null, "ECCPUBLICBLOB", cast(ubyte*)&keyBlob, keyBlob.sizeof, &res, 0)
					.ntEnforce("Cannot export private key.");
				assert(res == keyBlob.sizeof);
				return fromBinary(staticArray!pubKeyLen([ubyte(0x04)] ~ keyBlob.XY[0..pubKeyLen-1]));
			}
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PublicKey fromPEM(in char[] prvKey)
			{
				return fromDER(pem2der(prvKey));
			}
			/***********************************************************************
			 * Private Key from DER binary
			 */
			static PublicKey fromDER(in ubyte[] pubKey)
			{
				const(ubyte)[] der = pubKey[];
				auto seq = decasn1seq(der);
				auto oids = decasn1seq(seq);
				enforce(decasn1(0x06, oids) == [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01].bin,
					"Unsupported DER format.");
				enforce(decasn1(0x06, oids) == getOid!type, "Unsupported DER format.");
				auto pubKeyValue = decasn1str(seq);
				enforce(pubKeyValue.length == pubKeyLen, "Miss match key type.");
				return fromBinary(pubKeyValue[0..pubKeyLen]);
			}
			/***********************************************************************
			 * Private Key from 256bit binary
			 */
			static PublicKey fromBinary(in BinaryKey!pubKeyLen pubKey)
			{
				BCRYPT_ALG_HANDLE hAlg;
				BCRYPT_KEY_HANDLE hKey;
				enforce(pubKey[0] == 0x04, "Invalid public key format.");
				BCryptOpenAlgorithmProvider(&hAlg, algorithmName, null, 0)
					.ntEnforce("Cannot create private key.");
				scope (failure)
					cast(void)BCryptCloseAlgorithmProvider(hAlg, 0);
				setCurveParameters(hAlg);
				struct KeyBlob
				{
				align(1):
					ULONG dwMagic;
					ULONG cbKey;
					BYTE[pubKeyLen-1] XY; // Public Key
				}
				KeyBlob keyBlob;
				keyBlob.dwMagic = pubKeyMagicValue;
				keyBlob.cbKey = (pubKeyLen-1)/2;
				keyBlob.XY[] = pubKey[1..$];
				BCryptImportKeyPair(hAlg, null, "ECCPUBLICBLOB", &hKey, cast(ubyte*)&keyBlob, keyBlob.sizeof,
					BCRYPT_NO_KEY_VALIDATION)
					.ntEnforce("Cannot create public key.");
				return makeInst(hAlg, hKey);
			}
			/***********************************************************************
			 * Public Key to PEM string
			 */
			PEMString toPEM() const
			{
				return toDER().der2pem("PUBLIC KEY");
			}
			/***********************************************************************
			 * Public Key to DER binary
			 */
			DERBinary toDER() const
			{
				return encasn1seq( // SEQUENCE
					encasn1seq( // SEQUENCE
						encasn1(0x06, [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01].bin)   // OID: 1.2.840.10045.2.1 (EC Public Key)
						~ encasn1(0x06, getOid!type)                                    // OID: ex) 1.2.840.10045.3.1.7 (P-256)
					) ~ encasn1str(toBinary[])); // BIT STRING (Public Key)
			}
			/***********************************************************************
			 * Private Key to raw binary
			 */
			BinaryKey!pubKeyLen toBinary() const
			{
				struct KeyBlob
				{
				align(1):
					ULONG dwMagic;
					ULONG cbKey;
					BYTE[pubKeyLen-1] XY; // Public Key
				}
				KeyBlob keyBlob;
				keyBlob.dwMagic = pubKeyMagicValue;
				keyBlob.cbKey = (pubKeyLen-1)/2;
				ULONG res;
				BCryptExportKey(_key, null, "ECCPUBLICBLOB", cast(ubyte*)&keyBlob, keyBlob.sizeof, &res, 0)
					.ntEnforce("Cannot export private key.");
				assert(res == keyBlob.sizeof);
				return staticArray!pubKeyLen([0x04].bin ~ keyBlob.XY[]);
			}
		}
		
		
		/***********************************************************************
		 * 署名
		 */
		bin_t sign(in ubyte[] message, in PrivateKey prvKey)
		{
			ULONG len;
			BCryptSignHash(prvKey._key, null, cast(PUCHAR)message.ptr, cast(ULONG)message.length, null, 0, &len, 0)
				.ntEnforce("Cannot sign specified message.");
			assert(len == prvKeyLen*2);
			auto ret = new ubyte[prvKeyLen*2];
			BCryptSignHash(prvKey._key, null, cast(PUCHAR)message.ptr, cast(ULONG)message.length,
				ret.ptr, cast(ULONG)ret.length, &len, 0)
				.ntEnforce("Cannot sign specified message.");
			return ret.assumeUnique;
		}
		
		/***********************************************************************
		 * 検証
		 */
		bool verify(in ubyte[] message, in ubyte[] signature, in PublicKey pubKey)
		{
			auto res = BCryptVerifySignature(pubKey._key, null, cast(PUCHAR)message.ptr, cast(ULONG)message.length,
				cast(PUCHAR)signature.ptr, cast(ULONG)signature.length, 0);
			return res == 0;
		}
	}
	///
	alias BcryptECDSAP256Engine = BcryptECDSAEngine!(ECDSAType.p256);
	///
	alias BcryptECDSAP256KEngine = BcryptECDSAEngine!(ECDSAType.p256k);
	///
	alias BcryptECDSAP384Engine = BcryptECDSAEngine!(ECDSAType.p384);
	///
	alias BcryptECDSAP521Engine = BcryptECDSAEngine!(ECDSAType.p521);
	///
	private struct BcryptRSA4096Engine
	{
		struct PrvDat
		{
			ubyte[512] modulus;             // n
			ubyte[4]   publicExponent;      // e
			ubyte[512] privateExponent;     // d
			ubyte[256] prime1;              // p
			ubyte[256] prime2;              // q
			ubyte[256] exponent1;           // d mod (p-1)
			ubyte[256] exponent2;           // d mod (q-1)
			ubyte[256] coefficient;         // q^(-1) mod p
		}
		struct PubDat
		{
			ubyte[512] modulus;             // n
			ubyte[4]   publicExponent;      // e
		}
		enum prvKeyLen = PrvDat.sizeof;
		enum pubKeyLen = PubDat.sizeof;
		struct PrivateKey
		{
		private:
			import std.typecons: RefCounted, RefCountedAutoInitialize, refCounted;
			struct Instance
			{
				BCRYPT_ALG_HANDLE _hAlg;
				BCRYPT_KEY_HANDLE _hKey;
				@disable this(this);
				~this() @trusted
				{
					if (_hKey)
						cast(void)BCryptDestroyKey(_hKey);
					if (_hAlg)
						cast(void)BCryptCloseAlgorithmProvider(_hAlg, 0);
				}
			}
			RefCounted!(Instance, RefCountedAutoInitialize.no) _instance;
			static PrivateKey makeInst(BCRYPT_ALG_HANDLE alg, BCRYPT_KEY_HANDLE key)
			{
				return PrivateKey(refCounted(Instance(alg, key)));
			}
			BCRYPT_ALG_HANDLE _alg() inout
			{
				return cast(BCRYPT_ALG_HANDLE)_instance._hAlg;
			}
			BCRYPT_KEY_HANDLE _key() inout
			{
				return cast(BCRYPT_KEY_HANDLE)_instance._hKey;
			}
		public:
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PrivateKey createKey()
			{
				BCRYPT_ALG_HANDLE hAlg;
				BCRYPT_KEY_HANDLE hKey;
				BCryptOpenAlgorithmProvider(&hAlg, "RSA", null, 0)
					.ntEnforce("Cannot create private key.");
				scope (failure)
					cast(void)BCryptCloseAlgorithmProvider(hAlg, 0);
				BCryptGenerateKeyPair(hAlg, &hKey, 4096, 0)
					.ntEnforce("Cannot create private key.");
				scope (failure)
					cast(void)BCryptDestroyKey(hKey);
				BCryptFinalizeKeyPair(hKey, 0)
					.ntEnforce("Cannot create private key.");
				return makeInst(hAlg, hKey);
			}
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PrivateKey fromPEM(in char[] prvKey)
			{
				return fromDER(pem2der(prvKey));
			}
			/***********************************************************************
			 * Private Key from DER binary
			 */
			static PrivateKey fromDER(in ubyte[] prvKey)
			{
				BCRYPT_ALG_HANDLE hAlg;
				BCRYPT_KEY_HANDLE hKey;
				BCryptOpenAlgorithmProvider(&hAlg, "RSA", null, 0)
					.ntEnforce("Cannot create private key.");
				scope (failure)
					cast(void)BCryptCloseAlgorithmProvider(hAlg, 0);
				struct RSAPrivateBlob
				{
					ULONG     Magic;
					ULONG     BitLength;
					ULONG     cbPublicExp;
					ULONG     cbModulus;
					ULONG     cbPrime1;
					ULONG     cbPrime2;
					BYTE[4]   PublicExponent;
					BYTE[512] Modulus;
					BYTE[256] Prime1;
					BYTE[256] Prime2;
					BYTE[256] Exponent1;
					BYTE[256] Exponent2;
					BYTE[256] Coefficient;
					BYTE[512] PrivateExponent;
				}
				RSAPrivateBlob keyPair;
				keyPair.Magic = BCRYPT_RSAFULLPRIVATE_MAGIC;
				keyPair.BitLength = 4096;
				keyPair.cbPublicExp = 4;
				keyPair.cbModulus = 512;
				keyPair.cbPrime1 = 256;
				keyPair.cbPrime2 = 256;
				
				auto derall = prvKey[];
				auto der = decasn1seq(derall);
				auto ver = decasn1bn(der);
				enforce(ver.length == 1 && ver[0] == 0x00, "Invalid private key format.");
				keyPair.Modulus[0..512]         = decasn1bn(der, 512)[0..512];
				keyPair.PublicExponent[0..4]    = decasn1bn(der, 4)[0..4];
				keyPair.PrivateExponent[0..512] = decasn1bn(der, 512)[0..512];
				keyPair.Prime1[0..256]          = decasn1bn(der, 256)[0..256];
				keyPair.Prime2[0..256]          = decasn1bn(der, 256)[0..256];
				keyPair.Exponent1[0..256]       = decasn1bn(der, 256)[0..256];
				keyPair.Exponent2[0..256]       = decasn1bn(der, 256)[0..256];
				keyPair.Coefficient[0..256]     = decasn1bn(der, 256)[0..256];
				BCryptImportKeyPair(hAlg, null, "RSAFULLPRIVATEBLOB", &hKey, cast(ubyte*)&keyPair, keyPair.sizeof, 0)
					.ntEnforce("Cannot create private key.");
				return makeInst(hAlg, hKey);
			}
			/***********************************************************************
			 * Private Key from 256bit binary
			 */
			static PrivateKey fromBinary(in BinaryKey!prvKeyLen prvKey)
			{
				BCRYPT_ALG_HANDLE hAlg;
				BCRYPT_KEY_HANDLE hKey;
				BCryptOpenAlgorithmProvider(&hAlg, "RSA", null, 0)
					.ntEnforce("Cannot create private key.");
				scope (failure)
					cast(void)BCryptCloseAlgorithmProvider(hAlg, 0);
				struct RSAPrivateBlob
				{
					ULONG     Magic;
					ULONG     BitLength;
					ULONG     cbPublicExp;
					ULONG     cbModulus;
					ULONG     cbPrime1;
					ULONG     cbPrime2;
					BYTE[4]   PublicExponent;
					BYTE[512] Modulus;
					BYTE[256] Prime1;
					BYTE[256] Prime2;
					BYTE[256] Exponent1;
					BYTE[256] Exponent2;
					BYTE[256] Coefficient;
					BYTE[512] PrivateExponent;
				}
				RSAPrivateBlob keyBlob;
				keyBlob.Magic = BCRYPT_RSAFULLPRIVATE_MAGIC;
				keyBlob.BitLength = 4096;
				keyBlob.cbPublicExp = 4;
				keyBlob.cbModulus = 512;
				keyBlob.cbPrime1 = 256;
				keyBlob.cbPrime2 = 256;
				auto dat = *cast(PrvDat*)prvKey.ptr;
				keyBlob.PublicExponent[0..4]    = dat.publicExponent[0..4];
				keyBlob.Modulus[0..512]         = dat.modulus[0..512];
				keyBlob.Prime1[0..256]          = dat.prime1[0..256];
				keyBlob.Prime2[0..256]          = dat.prime2[0..256];
				keyBlob.Exponent1[0..256]       = dat.exponent1[0..256];
				keyBlob.Exponent2[0..256]       = dat.exponent2[0..256];
				keyBlob.Coefficient[0..256]     = dat.coefficient[0..256];
				keyBlob.PrivateExponent[0..512] = dat.privateExponent[0..512];
				BCryptImportKeyPair(hAlg, null, "RSAFULLPRIVATEBLOB", &hKey, cast(ubyte*)&keyBlob, keyBlob.sizeof, 0)
					.ntEnforce("Cannot create private key.");
				return makeInst(hAlg, hKey);
			}
			/***********************************************************************
			 * Private Key to PEM string
			 */
			PEMString toPEM() const
			{
				return toDER().der2pem("RSA PRIVATE KEY");
			}
			/***********************************************************************
			 * Private Key to DER binary
			 */
			DERBinary toDER() const
			{
				struct RSAPrivateBlob
				{
				align(1):
					ULONG     Magic;
					ULONG     BitLength;
					ULONG     cbPublicExp;
					ULONG     cbModulus;
					ULONG     cbPrime1;
					ULONG     cbPrime2;
					BYTE[2560] keyInfo;
				}
				RSAPrivateBlob keyBlob;
				keyBlob.Magic = BCRYPT_RSAFULLPRIVATE_MAGIC;
				
				ULONG res;
				BCryptExportKey(_key, null, "RSAFULLPRIVATEBLOB", cast(ubyte*)&keyBlob, keyBlob.sizeof, &res, 0)
					.ntEnforce("Cannot export private key.");
				
				ubyte[] pop(ref ubyte[] buf, size_t len)
				{
					enforce(len <= buf.length, "Cannot export private key.");
					auto retBuf = buf[0..len];
					buf = buf[len .. $];
					return retBuf;
				}
				auto ki = keyBlob.keyInfo[];
				auto publicExponent  = pop(ki, keyBlob.cbPublicExp);
				auto modulus         = pop(ki, keyBlob.cbModulus);
				auto prime1          = pop(ki, keyBlob.cbPrime1);
				auto prime2          = pop(ki, keyBlob.cbPrime2);
				auto exponent1       = pop(ki, keyBlob.cbPrime1);
				auto exponent2       = pop(ki, keyBlob.cbPrime2);
				auto coefficient     = pop(ki, keyBlob.cbPrime1);
				auto privateExponent = pop(ki, keyBlob.cbModulus);
				
				return encasn1seq(cast(immutable(ubyte)[])[0x02, 0x01, 0x00]
					~ encasn1bn(modulus[])
					~ encasn1bn(publicExponent[])
					~ encasn1bn(privateExponent[])
					~ encasn1bn(prime1[])
					~ encasn1bn(prime2[])
					~ encasn1bn(exponent1[])
					~ encasn1bn(exponent2[])
					~ encasn1bn(coefficient[]));
			}
			/***********************************************************************
			 * Private Key to 256bit binary
			 */
			BinaryKey!prvKeyLen toBinary() const
			{
				BinaryKey!prvKeyLen ret;
				struct RSAPrivateBlob
				{
					ULONG     Magic;
					ULONG     BitLength;
					ULONG     cbPublicExp;
					ULONG     cbModulus;
					ULONG     cbPrime1;
					ULONG     cbPrime2;
					BYTE[2560] keyInfo;
				}
				RSAPrivateBlob keyBlob;
				ULONG res;
				BCryptExportKey(_key, null, "RSAFULLPRIVATEBLOB", cast(ubyte*)&keyBlob, keyBlob.sizeof, &res, 0)
					.ntEnforce("Cannot export private key.");
				assert(keyBlob.Magic == BCRYPT_RSAFULLPRIVATE_MAGIC);
				ubyte[] pop(ref ubyte[] buf, size_t len)
				{
					enforce(len <= buf.length, "Cannot export private key.");
					auto retBuf = buf[0..len];
					buf = buf[len .. $];
					return retBuf;
				}
				auto ki = keyBlob.keyInfo[];
				auto publicExponent  = pop(ki, keyBlob.cbPublicExp);
				auto modulus         = pop(ki, keyBlob.cbModulus);
				auto prime1          = pop(ki, keyBlob.cbPrime1);
				auto prime2          = pop(ki, keyBlob.cbPrime2);
				auto exponent1       = pop(ki, keyBlob.cbPrime1);
				auto exponent2       = pop(ki, keyBlob.cbPrime2);
				auto coefficient     = pop(ki, keyBlob.cbPrime1);
				auto privateExponent = pop(ki, keyBlob.cbModulus);
				
				void cpBk(in ubyte[] src, ubyte[] dst)
				{
					enforce(dst.length >= src.length);
					dst[$-src.length .. $] = src[];
				}
				auto dat = cast(PrvDat*)ret.ptr;
				cpBk(publicExponent[], dat.publicExponent[]);
				cpBk(modulus[], dat.modulus[]);
				cpBk(prime1[], dat.prime1[]);
				cpBk(prime2[], dat.prime2[]);
				cpBk(exponent1[], dat.exponent1[]);
				cpBk(exponent2[], dat.exponent2[]);
				cpBk(coefficient[], dat.coefficient[]);
				cpBk(privateExponent[], dat.privateExponent[]);
				return ret;
			}
		}
		struct PublicKey
		{
		private:
			import std.typecons: RefCounted, RefCountedAutoInitialize, refCounted;
			struct Instance
			{
				BCRYPT_ALG_HANDLE _hAlg;
				BCRYPT_KEY_HANDLE _hKey;
				@disable this(this);
				~this() @trusted
				{
					if (_hKey)
						cast(void)BCryptDestroyKey(_hKey);
					if (_hAlg)
						cast(void)BCryptCloseAlgorithmProvider(_hAlg, 0);
				}
			}
			RefCounted!(Instance, RefCountedAutoInitialize.no) _instance;
			static PublicKey makeInst(BCRYPT_ALG_HANDLE alg, BCRYPT_KEY_HANDLE key)
			{
				return PublicKey(refCounted(Instance(alg, key)));
			}
			BCRYPT_ALG_HANDLE _alg() inout
			{
				return cast(BCRYPT_ALG_HANDLE)_instance._hAlg;
			}
			BCRYPT_KEY_HANDLE _key() inout
			{
				return cast(BCRYPT_KEY_HANDLE)_instance._hKey;
			}
		public:
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PublicKey createKey(PrivateKey prvKey)
			{
				BCRYPT_ALG_HANDLE hAlg;
				BCRYPT_KEY_HANDLE hKey;
				BCryptOpenAlgorithmProvider(&hAlg, "RSA", null, 0)
					.ntEnforce("Cannot create private key.");
				scope (failure)
					cast(void)BCryptCloseAlgorithmProvider(hAlg, 0);
				struct RSAPublicBlob
				{
					ULONG     Magic;
					ULONG     BitLength;
					ULONG     cbPublicExp;
					ULONG     cbModulus;
					ULONG     cbPrime1;
					ULONG     cbPrime2;
					BYTE[1536] keyInfo;
				}
				RSAPublicBlob keyBlob;
				ULONG res;
				BCryptExportKey(prvKey._key, null, "RSAPUBLICBLOB", cast(ubyte*)&keyBlob, keyBlob.sizeof, &res, 0)
					.ntEnforce("Cannot create public key.");
				
				BCryptImportKeyPair(hAlg, null, "RSAPUBLICBLOB", &hKey, cast(ubyte*)&keyBlob, res, 0)
					.ntEnforce("Cannot create public key.");
				
				return makeInst(hAlg, hKey);
			}
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PublicKey fromPEM(in char[] prvKey)
			{
				return fromDER(pem2der(prvKey));
			}
			/***********************************************************************
			 * Private Key from DER binary
			 */
			static PublicKey fromDER(in ubyte[] pubKey)
			{
				BCRYPT_ALG_HANDLE hAlg;
				BCRYPT_KEY_HANDLE hKey;
				BCryptOpenAlgorithmProvider(&hAlg, "RSA", null, 0)
					.ntEnforce("Cannot create public key.");
				scope (failure)
					cast(void)BCryptCloseAlgorithmProvider(hAlg, 0);
				struct RSAPublicBlob
				{
					ULONG     Magic;
					ULONG     BitLength;
					ULONG     cbPublicExp;
					ULONG     cbModulus;
					ULONG     cbPrime1;
					ULONG     cbPrime2;
					BYTE[4]   PublicExponent;
					BYTE[512] Modulus;
				}
				RSAPublicBlob keyBlob;
				keyBlob.Magic       = BCRYPT_RSAPUBLIC_MAGIC;
				keyBlob.BitLength   = 4096;
				keyBlob.cbPublicExp = 4;
				keyBlob.cbModulus   = 512;
				keyBlob.cbPrime1    = 0;
				keyBlob.cbPrime2    = 0;
				const(ubyte)[] derall = pubKey[];
				auto derseq = decasn1seq(derall);
				auto objId  = decasn1seq(derseq);
				auto contentStr  = decasn1str(derseq);
				auto pubKeyDat   = decasn1seq(contentStr);
				keyBlob.Modulus[0..512]      = decasn1bn(pubKeyDat, 512)[0..512];
				keyBlob.PublicExponent[0..4] = decasn1bn(pubKeyDat, 4)[0..4];
				BCryptImportKeyPair(hAlg, null, "RSAPUBLICBLOB", &hKey, cast(ubyte*)&keyBlob, keyBlob.sizeof, 0)
					.ntEnforce("Cannot create public key.");
				return makeInst(hAlg, hKey);
			}
			/***********************************************************************
			 * Private Key from 256bit binary
			 */
			static PublicKey fromBinary(in BinaryKey!pubKeyLen pubKey)
			{
				BCRYPT_ALG_HANDLE hAlg;
				BCRYPT_KEY_HANDLE hKey;
				BCryptOpenAlgorithmProvider(&hAlg, "RSA", null, 0)
					.ntEnforce("Cannot create public key.");
				scope (failure)
					cast(void)BCryptCloseAlgorithmProvider(hAlg, 0);
				struct RSAPublicBlob
				{
					ULONG     Magic;
					ULONG     BitLength;
					ULONG     cbPublicExp;
					ULONG     cbModulus;
					ULONG     cbPrime1;
					ULONG     cbPrime2;
					BYTE[4]   PublicExponent;
					BYTE[512] Modulus;
				}
				auto dat = cast(PubDat*)pubKey.ptr;
				RSAPublicBlob keyBlob;
				keyBlob.Magic       = BCRYPT_RSAPUBLIC_MAGIC;
				keyBlob.BitLength   = 4096;
				keyBlob.cbPublicExp = 4;
				keyBlob.cbModulus   = 512;
				keyBlob.cbPrime1    = 0;
				keyBlob.cbPrime2    = 0;
				keyBlob.PublicExponent[] = dat.publicExponent[];
				keyBlob.Modulus[]        = dat.modulus[];
				BCryptImportKeyPair(hAlg, null, "RSAPUBLICBLOB", &hKey, cast(ubyte*)&keyBlob, keyBlob.sizeof, 0)
					.ntEnforce("Cannot create public key.");
				return makeInst(hAlg, hKey);
			}
			/***********************************************************************
			 * Public Key to PEM string
			 */
			PEMString toPEM() const
			{
				return toDER().der2pem("PUBLIC KEY");
			}
			/***********************************************************************
			 * Public Key to DER binary
			 */
			DERBinary toDER() const
			{
				struct RSAPublicBlob
				{
					ULONG     Magic;
					ULONG     BitLength;
					ULONG     cbPublicExp;
					ULONG     cbModulus;
					ULONG     cbPrime1;
					ULONG     cbPrime2;
					BYTE[1536] keyInfo;
				}
				RSAPublicBlob keyBlob;
				ULONG res;
				BCryptExportKey(_key, null, "RSAPUBLICBLOB", cast(ubyte*)&keyBlob, keyBlob.sizeof, &res, 0)
					.ntEnforce("Cannot create public key.");
				
				ubyte[] pop(ref ubyte[] buf, size_t len)
				{
					enforce(len <= buf.length, "Cannot export private key.");
					auto retBuf = buf[0..len];
					buf = buf[len .. $];
					return retBuf;
				}
				auto ki = keyBlob.keyInfo[];
				auto publicExponent  = pop(ki, keyBlob.cbPublicExp);
				auto modulus         = pop(ki, keyBlob.cbModulus);
				return encasn1seq(
					encasn1seq(cast(ubyte[])[0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
					~ encasn1str(encasn1seq(
						encasn1bn(modulus)
						~ encasn1bn(publicExponent))));
			}
			/***********************************************************************
			 * Private Key to 256bit binary
			 */
			BinaryKey!pubKeyLen toBinary() const
			{
				BinaryKey!pubKeyLen ret;
				struct RSAPublicBlob
				{
					ULONG     Magic;
					ULONG     BitLength;
					ULONG     cbPublicExp;
					ULONG     cbModulus;
					ULONG     cbPrime1;
					ULONG     cbPrime2;
					BYTE[1536] keyInfo;
				}
				RSAPublicBlob keyBlob;
				ULONG res;
				BCryptExportKey(_key, null, "RSAPUBLICBLOB", cast(ubyte*)&keyBlob, keyBlob.sizeof, &res, 0)
					.ntEnforce("Cannot create public key.");
				
				ubyte[] pop(ref ubyte[] buf, size_t len)
				{
					enforce(len <= buf.length, "Cannot export private key.");
					auto retBuf = buf[0..len];
					buf = buf[len .. $];
					return retBuf;
				}
				auto ki = keyBlob.keyInfo[];
				auto publicExponent  = pop(ki, keyBlob.cbPublicExp);
				auto modulus         = pop(ki, keyBlob.cbModulus);
				void cpBk(in ubyte[] src, ubyte[] dst)
				{
					enforce(dst.length >= src.length);
					dst[$-src.length .. $] = src[];
				}
				auto dat = cast(PrvDat*)ret.ptr;
				cpBk(publicExponent[], dat.publicExponent[]);
				cpBk(modulus[], dat.modulus[]);
				return ret;
			}
		}
		
		
		/***********************************************************************
		 * 署名
		 */
		bin_t sign(in ubyte[] message, in PrivateKey prvKey)
		{
			import std.range;
			enforce(message.length <= 512 - 4, "Cannot sign specified message.");
			// PKCS#1 v1.5 Padding
			enum ubyte[512] ffFilled = repeat(ubyte(0xFF), 512).array;
			auto head = cast(ubyte[])[0x00, 0x01] ~ ffFilled[0..512 - 3 - message.length] ~ cast(ubyte[])[0x00];
			auto msg = head ~ message;
			assert(msg.length == 512);
			auto signData = new ubyte[512];
			ULONG len;
			// 署名処理 = 署名データをRSA復号(mod N での冪乗)する
			BCryptDecrypt(prvKey._key, cast(ubyte*)msg.ptr, cast(ULONG)msg.length, null, null, 0,
				signData.ptr, cast(ULONG)signData.length, &len, 0)
				.ntEnforce("Cannot sign specified message.");
			assert(len == 512);
			return signData[0..len].assumeUnique;
		}
		
		/***********************************************************************
		 * 検証
		 */
		bool verify(in ubyte[] message, in ubyte[] signature, in PublicKey pubKey)
		{
			enforce(message.length <= 512 - 4, "Cannot verify specified message.");
			enforce(signature.length == 512, "Cannot verify specified message.");
			// PKCS#1 v1.5 Padding
			enum ubyte[512] ffFilled = repeat(ubyte(0xFF), 512).array;
			auto head = cast(ubyte[])[0x00, 0x01] ~ ffFilled[0..512 - 3 - message.length] ~ cast(ubyte[])[0x00];
			auto msg = head ~ message;
			assert(msg.length == 512);
			ubyte[512] checkData;
			ULONG len;
			// 検証処理 = 署名データをRSA暗号化(mod N での冪乗)して、暗号文がメッセージ本文と同一か確認する
			BCryptEncrypt(pubKey._key, cast(PUCHAR)signature.ptr, cast(ULONG)signature.length, null, null, 0,
				cast(PUCHAR)checkData.ptr, cast(ULONG)checkData.length, &len, 0)
				.ntEnforce("Cannot verify specified message.");
			return checkData[] == msg[];
		}
		
		/***********************************************************************
		 * 暗号化
		 */
		bin_t encrypt(in ubyte[] data, in PublicKey pubKey)
		{
			enforce(data.length <= 512 - 4, "Cannot encrypt specified data.");
			// PKCS#1 v1.5 Padding
			enum ubyte[512] ffFilled = repeat(ubyte(0xFF), 512).array;
			auto head = cast(ubyte[])[0x00, 0x01] ~ ffFilled[0..512 - 3 - data.length] ~ cast(ubyte[])[0x00];
			auto msg = head ~ data;
			assert(msg.length == 512);
			auto encrypted = new ubyte[512];
			ULONG len;
			BCryptEncrypt(pubKey._key, cast(PUCHAR)msg.ptr, cast(ULONG)msg.length, null, null, 0,
				cast(PUCHAR)encrypted.ptr, cast(ULONG)encrypted.length, &len, 0)
				.ntEnforce("Cannot encrypt specified data.");
			assert(len == 512);
			return encrypted[0..len].assumeUnique;
		}
		
		/***********************************************************************
		 * 復号
		 */
		bin_t decrypt(in ubyte[] data, in PrivateKey prvKey)
		{
			import std.algorithm: find;
			enforce(data.length == 512, "Cannot decrypt specified data.");
			auto decrypted = new ubyte[512];
			ULONG len;
			BCryptDecrypt(prvKey._key, cast(ubyte*)data.ptr, cast(ULONG)data.length, null, null, 0,
				decrypted.ptr, cast(ULONG)decrypted.length, &len, 0)
				.ntEnforce("Cannot decrypt specified data.");
			assert(len == 512);
			// Remove PKCS#1 v1.5 Padding
			enforce(decrypted[0..3] == [0x00, 0x01, 0xFF], "Cannot decrypt specified data.");
			auto found = find(decrypted[3..len], 0x00);
			enforce(!found.empty && found.length > 0, "Cannot decrypt specified data.");
			assert(found.front == 0x00);
			return found[1..$].assumeUnique;
		}
	}
	///
	private struct BcryptECDHP256Engine
	{
		enum prvKeyLen = 32;
		enum pubKeyLen = 65;
		struct PrivateKey
		{
		private:
			import std.typecons: RefCounted, RefCountedAutoInitialize, refCounted;
			struct Instance
			{
				BCRYPT_ALG_HANDLE _hAlg;
				BCRYPT_KEY_HANDLE _hKey;
				@disable this(this);
				~this() @trusted
				{
					if (_hKey)
						cast(void)BCryptDestroyKey(_hKey);
					if (_hAlg)
						cast(void)BCryptCloseAlgorithmProvider(_hAlg, 0);
				}
			}
			RefCounted!(Instance, RefCountedAutoInitialize.no) _instance;
			static PrivateKey makeInst(BCRYPT_ALG_HANDLE alg, BCRYPT_KEY_HANDLE key)
			{
				return PrivateKey(refCounted(Instance(alg, key)));
			}
			BCRYPT_ALG_HANDLE _alg() inout
			{
				return cast(BCRYPT_ALG_HANDLE)_instance._hAlg;
			}
			BCRYPT_KEY_HANDLE _key() inout
			{
				return cast(BCRYPT_KEY_HANDLE)_instance._hKey;
			}
		public:
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PrivateKey createKey()
			{
				BCRYPT_ALG_HANDLE hAlg;
				BCRYPT_KEY_HANDLE hKey;
				BCryptOpenAlgorithmProvider(&hAlg, "ECDH_P256", null, 0)
					.ntEnforce("Cannot create private key.");
				scope (failure)
					cast(void)BCryptCloseAlgorithmProvider(hAlg, 0);
				BCryptGenerateKeyPair(hAlg, &hKey, 256, 0)
					.ntEnforce("Cannot create private key.");
				BCryptFinalizeKeyPair(hKey, 0)
					.ntEnforce("Cannot create private key.");
				return makeInst(hAlg, hKey);
			}
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PrivateKey fromPEM(in char[] prvKey)
			{
				return fromDER(pem2der(prvKey));
			}
			/***********************************************************************
			 * Private Key from DER binary
			 */
			static PrivateKey fromDER(in ubyte[] prvKey)
			{
				switch (prvKey.length)
				{
				case 121:
					enforce(prvKey[0 .. 7] == [0x30, 0x77, 0x02, 0x01, 0x01, 0x04, 0x20], "Unsupported DER format.");
					return fromBinary(prvKey[7..7+32]);
				default:
					enforce(0, "Unsupported DER format.");
				}
				return PrivateKey.init;
			}
			/***********************************************************************
			 * Private Key from 256bit binary
			 */
			static PrivateKey fromBinary(in BinaryKey!32 prvKey)
			{
				BCRYPT_ALG_HANDLE hAlg;
				BCRYPT_KEY_HANDLE hKey;
				BCryptOpenAlgorithmProvider(&hAlg, "ECDH_P256", null, 0)
					.ntEnforce("Cannot create private key.");
				scope (failure)
					cast(void)BCryptCloseAlgorithmProvider(hAlg, 0);
				struct BcryptKeyPair
				{
				align(1):
					ULONG dwMagic;
					ULONG cbKey;
					BYTE[64] XY; // Public Key
					BYTE[32] d;  // Private Key
				}
				BcryptKeyPair keyPair;
				keyPair.dwMagic = BCRYPT_ECDH_PRIVATE_P256_MAGIC;
				keyPair.cbKey = 32;
				keyPair.XY[] = 0;
				keyPair.d[] = prvKey[];
				BCryptImportKeyPair(hAlg, null, "ECCPRIVATEBLOB", &hKey, cast(ubyte*)&keyPair, keyPair.sizeof,
					BCRYPT_NO_KEY_VALIDATION)
					.ntEnforce("Cannot create private key.");
				return makeInst(hAlg, hKey);
			}
			/***********************************************************************
			 * Private Key to PEM string
			 */
			PEMString toPEM() const
			{
				return toDER().der2pem("EC PRIVATE KEY");
			}
			/***********************************************************************
			 * Private Key to DER binary
			 */
			DERBinary toDER() const
			{
				struct BcryptKeyPair
				{
				align(1):
					ULONG dwMagic;
					ULONG cbKey;
					BYTE[64] XY; // Public Key
					BYTE[32] d;  // Private key
				}
				BcryptKeyPair keyPair;
				keyPair.dwMagic = BCRYPT_ECDH_PRIVATE_P256_MAGIC;
				keyPair.cbKey = 32;
				ULONG res;
				BCryptExportKey(_key, null, "ECCPRIVATEBLOB", cast(ubyte*)&keyPair, keyPair.sizeof, &res, 0)
					.ntEnforce("Cannot export private key.");
				return assumeUnique(cast(ubyte[])[0x30, 0x77, // SEQUENCE
					0x02, 0x01, 0x01, // INTEGER  VERSION(1)
					0x04, 0x20] ~ keyPair.d[0..32] ~ cast(ubyte[])[ // OCTET STRING (Private Key)
					0xA0, 0x0A, // [0] EC PARAMETERS
						0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, // OID: 1.2.840.10045.3.1.7 (P-256)
					0xA1, 0x44, // [1] EC PUBLIC
						0x03, 0x42, 0x00, 0x04] ~ keyPair.XY[0..64]); // BIT STRING (Public Key)
			}
			/***********************************************************************
			 * Private Key to 256bit binary
			 */
			BinaryKey!32 toBinary() const
			{
				struct BcryptKeyPair
				{
				align(1):
					ULONG dwMagic;
					ULONG cbKey;
					BYTE[64] XY; // Public Key
					BYTE[32] d;  // Private key
				}
				BcryptKeyPair keyPair;
				keyPair.dwMagic = BCRYPT_ECDH_PRIVATE_P256_MAGIC;
				keyPair.cbKey = 32;
				ULONG res;
				BCryptExportKey(_key, null, "ECCPRIVATEBLOB", cast(ubyte*)&keyPair, keyPair.sizeof, &res, 0)
					.ntEnforce("Cannot export private key.");
				assert(res == keyPair.sizeof);
				return keyPair.d[0..32];
			}
		}
		struct PublicKey
		{
		private:
			import std.typecons: RefCounted, RefCountedAutoInitialize, refCounted;
			struct Instance
			{
				BCRYPT_ALG_HANDLE _hAlg;
				BCRYPT_KEY_HANDLE _hKey;
				@disable this(this);
				~this() @trusted
				{
					if (_hKey)
						cast(void)BCryptDestroyKey(_hKey);
					if (_hAlg)
						cast(void)BCryptCloseAlgorithmProvider(_hAlg, 0);
				}
			}
			RefCounted!(Instance, RefCountedAutoInitialize.no) _instance;
			static PublicKey makeInst(BCRYPT_ALG_HANDLE alg, BCRYPT_KEY_HANDLE key)
			{
				return PublicKey(refCounted(Instance(alg, key)));
			}
			BCRYPT_ALG_HANDLE _alg() inout
			{
				return cast(BCRYPT_ALG_HANDLE)_instance._hAlg;
			}
			BCRYPT_KEY_HANDLE _key() inout
			{
				return cast(BCRYPT_KEY_HANDLE)_instance._hKey;
			}
		public:
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PublicKey createKey(PrivateKey prvKey)
			{
				struct KeyBlob
				{
				align(1):
					ULONG dwMagic;
					ULONG cbKey;
					BYTE[64] XY; // Public Key
				}
				KeyBlob keyBlob;
				keyBlob.dwMagic = BCRYPT_ECDH_PUBLIC_P256_MAGIC;
				keyBlob.cbKey = 32;
				ULONG res;
				BCryptExportKey(prvKey._key, null, "ECCPUBLICBLOB", cast(ubyte*)&keyBlob, keyBlob.sizeof, &res, 0)
					.ntEnforce("Cannot export private key.");
				assert(res == keyBlob.sizeof);
				return fromBinary(staticArray!65([ubyte(0x04)] ~ keyBlob.XY[0..64]));
			}
			/***********************************************************************
			 * Private Key from PEM string
			 */
			static PublicKey fromPEM(in char[] prvKey)
			{
				return fromDER(pem2der(prvKey));
			}
			/***********************************************************************
			 * Private Key from DER binary
			 */
			static PublicKey fromDER(in ubyte[] pubKey)
			{
				switch (pubKey.length)
				{
				case 91:
					enforce(pubKey[0 .. 4] == [0x30, 0x59, 0x30, 0x13], "Unsupported DER format.");
					enforce(pubKey[4 .. 13] == [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01],
						"Unsupported DER format.");
					enforce(pubKey[13 .. 23] == [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07],
						"Unsupported DER format.");
					enforce(pubKey[23 .. 25] == [0x03, 0x42],
						"Unsupported DER format.");
					return fromBinary(pubKey[26..26+65]);
				default:
					enforce(0, "Unsupported DER format.");
				}
				return PublicKey.init;
			}
			/***********************************************************************
			 * Private Key from 256bit binary
			 */
			static PublicKey fromBinary(in BinaryKey!65 pubKey)
			{
				BCRYPT_ALG_HANDLE hAlg;
				BCRYPT_KEY_HANDLE hKey;
				enforce(pubKey[0] == 0x04, "Invalid public key format.");
				BCryptOpenAlgorithmProvider(&hAlg, "ECDH_P256", null, 0)
					.ntEnforce("Cannot create private key.");
				scope (failure)
					cast(void)BCryptCloseAlgorithmProvider(hAlg, 0);
				struct KeyBlob
				{
				align(1):
					ULONG dwMagic;
					ULONG cbKey;
					BYTE[64] XY; // Public Key
				}
				KeyBlob keyBlob;
				keyBlob.dwMagic = BCRYPT_ECDH_PUBLIC_P256_MAGIC;
				keyBlob.cbKey = 32;
				keyBlob.XY[] = pubKey[1..$];
				BCryptImportKeyPair(hAlg, null, "ECCPUBLICBLOB", &hKey, cast(ubyte*)&keyBlob, keyBlob.sizeof,
					BCRYPT_NO_KEY_VALIDATION)
					.ntEnforce("Cannot create public key.");
				return makeInst(hAlg, hKey);
			}
			/***********************************************************************
			 * Public Key to PEM string
			 */
			PEMString toPEM() const
			{
				return toDER().der2pem("PUBLIC KEY");
			}
			/***********************************************************************
			 * Public Key to DER binary
			 */
			DERBinary toDER() const
			{
				return assumeUnique(cast(ubyte[])[0x30, 0x59, // SEQUENCE
					0x30, 0x13, // SEQUENCE
					0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,       // OID: 1.2.840.10045.2.1 (EC Public Key)
					0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07, // OID: 1.2.840.10045.3.1.7 (P-256)
					0x03, 0x42, 0x00] ~ toBinary[0..65]); // BIT STRING (Public Key)
			}
			/***********************************************************************
			 * Private Key to 256bit binary
			 */
			BinaryKey!65 toBinary() const
			{
				struct KeyBlob
				{
				align(1):
					ULONG dwMagic;
					ULONG cbKey;
					BYTE[64] XY; // Public Key
				}
				KeyBlob keyBlob;
				keyBlob.dwMagic = BCRYPT_ECDH_PUBLIC_P256_MAGIC;
				keyBlob.cbKey = 32;
				ULONG res;
				BCryptExportKey(_key, null, "ECCPUBLICBLOB", cast(ubyte*)&keyBlob, keyBlob.sizeof, &res, 0)
					.ntEnforce("Cannot export private key.");
				assert(res == keyBlob.sizeof);
				return staticArray!65([ubyte(0x04)] ~ keyBlob.XY[0..64]);
			}
		}
		/***********************************************************************
		 * Derive shared secret
		 */
		bin_t derive(in PrivateKey prvKey, in PublicKey pubKey)
		{
			BCRYPT_SECRET_HANDLE hSecret;
			BCryptSecretAgreement(prvKey._key, pubKey._key, &hSecret, 0)
				.ntEnforce("Cannot derive shared secret.");
			scope (exit)
				cast(void)BCryptDestroySecret(hSecret);
			DWORD len = 0;
			DWORD resultSize = 0;
			BCryptDeriveKey(hSecret, "TRUNCATE", null, null, 0, &len, 0)
				.ntEnforce("Cannot derive shared secret.");
			assert(len == 32);
			auto buf = new ubyte[len];
			BCryptDeriveKey(hSecret, "TRUNCATE", null, buf.ptr, cast(ULONG)buf.length, &len, 0)
				.ntEnforce("Cannot derive shared secret.");
			return buf[0..len].retro.array.assumeUnique;
		}
	}
}

//##############################################################################
//##### Helpers
//##############################################################################

static if (enableOpenSSLCmdEngines)
{
	///
	enum bool isOpenSSLCmdAESEngine(T) = false
		|| is(T == OpenSSLCmdAESCBCEncryptEngine)
		|| is(T == OpenSSLCmdAESCBCDecryptEngine);
	///
	enum bool isOpenSSLCmdEd25519Engine(T) = is(T == OpenSSLCmdEd25519Engine);
	///
	enum bool isOpenSSLCmdECDSAP256Engine(T) = is(T == OpenSSLCmdECDSAP256Engine);
	///
	enum bool isOpenSSLCmdECDSAP256KEngine(T) = is(T == OpenSSLCmdECDSAP256KEngine);
	///
	enum bool isOpenSSLCmdECDSAP384Engine(T) = is(T == OpenSSLCmdECDSAP384Engine);
	///
	enum bool isOpenSSLCmdECDSAP521Engine(T) = is(T == OpenSSLCmdECDSAP521Engine);
	///
	enum bool isOpenSSLCmdECDSAEngine(T) = false
		|| isOpenSSLCmdECDSAP256Engine!T
		|| isOpenSSLCmdECDSAP256KEngine!T
		|| isOpenSSLCmdECDSAP384Engine!T
		|| isOpenSSLCmdECDSAP521Engine!T;
	///
	enum bool isOpenSSLCmdRSA4096Engine(T) = is(T == OpenSSLCmdRSA4096Engine);
	///
	enum bool isOpenSSLCmdECDHP256Engine(T) = is(T == OpenSSLCmdECDHP256Engine);
}
else
{
	///
	enum bool isOpenSSLCmdAESEngine(T) = false;
	///
	enum bool isOpenSSLCmdEd25519Engine(T) = false;
	///
	enum bool isOpenSSLCmdECDSAP256Engine(T) = false;
	///
	enum bool isOpenSSLCmdECDSAP256KEngine(T) = false;
	///
	enum bool isOpenSSLCmdECDSAP384Engine(T) = false;
	///
	enum bool isOpenSSLCmdECDSAP521Engine(T) = false;
	///
	enum bool isOpenSSLCmdECDSAEngine(T) = false;
	///
	enum bool isOpenSSLCmdRSA4096Engine(T) = false;
	///
	enum bool isOpenSSLCmdECDHP256Engine(T) = false;
}

static if (enableOpenSSLEngines)
{
	///
	enum bool isOpenSSLAESEngine(T) = is(T == OpenSSLAESCBCEncryptEngine)
		|| is(T == OpenSSLAESCBCDecryptEngine);
	///
	enum bool isOpenSSLEd25519Engine(T) = is(T == OpenSSLEd25519Engine);
	///
	enum bool isOpenSSLECDSAP256Engine(T) = is(T == OpenSSLECDSAP256Engine);
	///
	enum bool isOpenSSLECDSAP256KEngine(T) = is(T == OpenSSLECDSAP256KEngine);
	///
	enum bool isOpenSSLECDSAP384Engine(T) = is(T == OpenSSLECDSAP384Engine);
	///
	enum bool isOpenSSLECDSAP521Engine(T) = is(T == OpenSSLECDSAP521Engine);
	///
	enum bool isOpenSSLECDSAEngine(T) = false
		|| isOpenSSLECDSAP256Engine!T
		|| isOpenSSLECDSAP256KEngine!T
		|| isOpenSSLECDSAP384Engine!T
		|| isOpenSSLECDSAP521Engine!T;
	///
	enum bool isOpenSSLRSA4096Engine(T) = is(T == OpenSSLRSA4096Engine);
	///
	enum bool isOpenSSLECDHP256Engine(T) = is(T == OpenSSLECDHP256Engine);
}
else
{
	///
	enum bool isOpenSSLAESEngine(T) = false;
	///
	enum bool isOpenSSLEd25519Engine(T) = false;
	///
	enum bool isOpenSSLECDSAP256Engine(T) = false;
	///
	enum bool isOpenSSLECDSAP256KEngine(T) = false;
	///
	enum bool isOpenSSLECDSAP384Engine(T) = false;
	///
	enum bool isOpenSSLECDSAP521Engine(T) = false;
	///
	enum bool isOpenSSLECDSAEngine(T) = false;
	///
	enum bool isOpenSSLRSA4096Engine(T) = false;
	///
	enum bool isOpenSSLECDHP256Engine(T) = false;
}

static if (enableBcryptEngines)
{
	///
	enum bool isBcryptAESEngine(T) = is(T == BcryptAESCBCEncryptEngine)
		|| is(T == BcryptAESCBCDecryptEngine);
	///
	enum bool isBcryptEd25519Engine(T) = false;
	///
	enum bool isBcryptECDSAP256Engine(T) = is(T == BcryptECDSAP256Engine);
	///
	enum bool isBcryptECDSAP256KEngine(T) = is(T == BcryptECDSAP256KEngine);
	///
	enum bool isBcryptECDSAP384Engine(T) = is(T == BcryptECDSAP384Engine);
	///
	enum bool isBcryptECDSAP521Engine(T) = is(T == BcryptECDSAP521Engine);
	///
	enum bool isBcryptECDSAEngine(T) = false
		|| isBcryptECDSAP256Engine!T
		|| isBcryptECDSAP256KEngine!T
		|| isBcryptECDSAP384Engine!T
		|| isBcryptECDSAP521Engine!T;
	///
	enum bool isBcryptRSA4096Engine(T) = is(T == BcryptRSA4096Engine);
	///
	enum bool isBcryptECDHP256Engine(T) = is(T == BcryptECDHP256Engine);
}
else
{
	///
	enum bool isBcryptAESEngine(T) = false;
	///
	enum bool isBcryptEd25519Engine(T) = false;
	///
	enum bool isBcryptECDSAP256Engine(T) = false;
	///
	enum bool isBcryptECDSAP256KEngine(T) = false;
	///
	enum bool isBcryptECDSAP384Engine(T) = false;
	///
	enum bool isBcryptECDSAP521Engine(T) = false;
	///
	enum bool isBcryptECDSAEngine(T) = false;
	///
	enum bool isBcryptRSA4096Engine(T) = false;
	///
	enum bool isBcryptECDHP256Engine(T) = false;
}

///
enum bool isOpenSSLCmdEngine(T) = isOpenSSLCmdAESEngine!T
	|| isOpenSSLCmdEd25519Engine!T
	|| isOpenSSLCmdECDSAP256Engine!T
	|| isOpenSSLCmdRSA4096Engine!T
	|| isOpenSSLCmdECDHP256Engine!T;
///
enum bool isOpenSSLEngine(T) = isOpenSSLAESEngine!T
	|| isOpenSSLEd25519Engine!T
	|| isOpenSSLECDSAP256Engine!T
	|| isOpenSSLRSA4096Engine!T
	|| isOpenSSLECDHP256Engine!T;
///
enum bool isBcryptEngine(T) = isBcryptAESEngine!T
	|| isBcryptEd25519Engine!T
	|| isBcryptECDSAP256Engine!T
	|| isBcryptRSA4096Engine!T
	|| isBcryptECDHP256Engine!T;
///
enum bool isAESEngine(T) = isOpenSSLCmdAESEngine!T
	|| isOpenSSLAESEngine!T
	|| isBcryptAESEngine!T;
///
enum bool isEd25519Engine(T) = isOpenSSLCmdEd25519Engine!T
	|| isOpenSSLEd25519Engine!T
	|| isBcryptEd25519Engine!T;
///
enum bool isECDSAP256Engine(T) = isOpenSSLCmdECDSAP256Engine!T
	|| isOpenSSLECDSAP256Engine!T
	|| isBcryptECDSAP256Engine!T;
///
enum bool isECDSAP256KEngine(T) = isOpenSSLCmdECDSAP256KEngine!T
	|| isOpenSSLECDSAP256KEngine!T
	|| isBcryptECDSAP256KEngine!T;
///
enum bool isECDSAP384Engine(T) = isOpenSSLCmdECDSAP384Engine!T
	|| isOpenSSLECDSAP384Engine!T
	|| isBcryptECDSAP384Engine!T;
///
enum bool isECDSAP521Engine(T) = isOpenSSLCmdECDSAP521Engine!T
	|| isOpenSSLECDSAP521Engine!T
	|| isBcryptECDSAP521Engine!T;
///
enum bool isECDSAEngine(T) = isOpenSSLCmdECDSAEngine!T
	|| isOpenSSLECDSAEngine!T
	|| isBcryptECDSAEngine!T;
///
enum bool isRSAEngine(T) = isOpenSSLCmdRSA4096Engine!T
	|| isOpenSSLRSA4096Engine!T
	|| isBcryptRSA4096Engine!T;
///
enum bool isECDHEngine(T) = isOpenSSLCmdECDHP256Engine!T
	|| isOpenSSLECDHP256Engine!T
	|| isBcryptECDHP256Engine!T;

static if (enableOpenSSLEngines)
{
	///
	alias DefaultAES128CBCEncryptEngine = OpenSSLAES128CBCEncryptEngine;
	///
	alias DefaultAES256CBCEncryptEngine = OpenSSLAES256CBCEncryptEngine;
	///
	alias DefaultAES128CBCDecryptEngine = OpenSSLAES128CBCDecryptEngine;
	///
	alias DefaultAES256CBCDecryptEngine = OpenSSLAES256CBCDecryptEngine;
	///
	alias DefaultEd25519Engine = OpenSSLEd25519Engine;
	///
	alias DefaultECDSAP256Engine = OpenSSLECDSAP256Engine;
	///
	alias DefaultECDSAP256KEngine = OpenSSLECDSAP256KEngine;
	///
	alias DefaultECDSAP384Engine = OpenSSLECDSAP384Engine;
	///
	alias DefaultECDSAP521Engine = OpenSSLECDSAP521Engine;
	///
	alias DefaultRSA4096Engine = OpenSSLRSA4096Engine;
	///
	alias DefaultECDHP256Engine = OpenSSLCmdECDHP256Engine;
}
else static if (enableBcryptEngines)
{
	///
	alias DefaultAES128CBCEncryptEngine = BcryptAES128CBCEncryptEngine;
	///
	alias DefaultAES256CBCEncryptEngine = BcryptAES256CBCEncryptEngine;
	///
	alias DefaultAES128CBCDecryptEngine = BcryptAES128CBCDecryptEngine;
	///
	alias DefaultAES256CBCDecryptEngine = BcryptAES256CBCDecryptEngine;
	///
	alias DefaultEd25519Engine = OpenSSLCmdEd25519Engine;
	///
	alias DefaultECDSAP256Engine = BcryptECDSAP256Engine;
	///
	alias DefaultECDSAP256KEngine = BcryptECDSAP256KEngine;
	///
	alias DefaultECDSAP384Engine = BcryptECDSAP384Engine;
	///
	alias DefaultECDSAP521Engine = BcryptECDSAP521Engine;
	///
	alias DefaultRSA4096Engine = BcryptRSA4096Engine;
	///
	alias DefaultECDHP256Engine = BcryptECDHP256Engine;
}
else
{
	///
	alias DefaultAES128CBCEncryptEngine = OpenSSLCmdAES128CBCEncryptEngine;
	///
	alias DefaultAES256CBCEncryptEngine = OpenSSLCmdAES256CBCEncryptEngine;
	///
	alias DefaultAES128CBCDecryptEngine = OpenSSLCmdAES128CBCDecryptEngine;
	///
	alias DefaultAES256CBCDecryptEngine = OpenSSLCmdAES256CBCDecryptEngine;
	///
	alias DefaultEd25519Engine = OpenSSLCmdEd25519Engine;
	///
	alias DefaultECDSAP256Engine = OpenSSLCmdECDSAP256Engine;
	///
	alias DefaultECDSAP256KEngine = OpenSSLCmdECDSAP256KEngine;
	///
	alias DefaultECDSAP384Engine = OpenSSLCmdECDSAP384Engine;
	///
	alias DefaultECDSAP521Engine = OpenSSLCmdECDSAP521Engine;
	///
	alias DefaultRSA4096Engine = OpenSSLCmdRSA4096Engine;
	///
	alias DefaultECDHP256Engine = OpenSSLCmdECDHP256Engine;
}


/*******************************************************************************
 * Encrypt
 */
struct Encrypter(Engine)
{
private:
	Engine _engine;
	static if (isRSAEngine!Engine)
	{
		enum _onlyOneShot = true;
		Engine.PublicKey _key;
	}
	else
	{
		Appender!(immutable(ubyte)[]) _dst;
		enum _onlyOneShot = false;
	}
	bool _padding;
	bool _finalized;
public:
	/***************************************************************************
	 * Constructor
	 */
	this(Engine engine, bool padding = true)
	{
		_engine = engine.move();
		static if (!_onlyOneShot)
			_dst = appender!(immutable(ubyte)[])();
		_padding = padding;
		_finalized = false;
	}
	/// ditto
	static if (isOpenSSLCmdEngine!Engine && isAESEngine!Engine)
	this(in ubyte[] key, in ubyte[] iv, bool padding = true, string cmd = defaultOpenSSLCommand)
	{
		this(Engine(key, iv, cmd), padding);
	}
	/// ditto
	static if ((isOpenSSLEngine!Engine || isBcryptEngine!Engine) && isAESEngine!Engine)
	this(in ubyte[] key, in ubyte[] iv, bool padding = true)
	{
		this(Engine(key, iv), padding);
	}
	/// ditto
	static if (isOpenSSLCmdEngine!Engine && isRSAEngine!Engine)
	this(in char[] pubKey, bool padding = true, string cmd = defaultOpenSSLCommand)
	{
		_key = Engine.PublicKey.fromPEM(pubKey);
		this(Engine(cmd), padding);
	}
	/// ditto
	static if (isOpenSSLCmdEngine!Engine && isRSAEngine!Engine)
	this(in ubyte[] pubKey, bool padding = true, string cmd = defaultOpenSSLCommand)
	{
		_key = Engine.PublicKey.fromDER(pubKey);
		this(cmd, padding);
	}
	/// ditto
	static if (isOpenSSLCmdEngine!Engine && isRSAEngine!Engine)
	this(in BinaryKey!(Engine.pubKeyLen) pubKey, bool padding = true, string cmd = defaultOpenSSLCommand)
	{
		_key = Engine.PublicKey.fromBinary(pubKey);
		this(cmd, padding);
	}
	/// ditto
	static if (!isOpenSSLCmdEngine!Engine && isRSAEngine!Engine)
	this(in char[] pubKey, bool padding = true)
	{
		_key = Engine.PublicKey.fromPEM(pubKey);
		this(Engine(), padding);
	}
	/// ditto
	static if (!isOpenSSLCmdEngine!Engine && isRSAEngine!Engine)
	this(in ubyte[] pubKey, bool padding = true)
	{
		_key = Engine.PublicKey.fromDER(pubKey);
		this(Engine(), padding);
	}
	/// ditto
	static if (!isOpenSSLCmdEngine!Engine && isRSAEngine!Engine)
	this(BinaryKey!(Engine.pubKeyLen) pubKey, bool padding = true)
	{
		_key = Engine.PublicKey.fromBinary(pubKey);
		this(Engine(), padding);
	}
	
	/***************************************************************************
	 * Update
	 */
	static if (!_onlyOneShot) void update(in ubyte[] data)
	in (!_finalized)
	{
		_engine.update(data, _dst);
	}
	/***************************************************************************
	 * Data
	 */
	static if (!_onlyOneShot) bin_t data()
	{
		if (!_finalized)
		{
			_engine.finalize(_dst, _padding);
			_finalized = true;
		}
		return _dst.data();
	}
	/***************************************************************************
	 * OneShot encrypt
	 */
	bin_t encrypt(in ubyte[] dat)
	{
		static if (_onlyOneShot)
		{
			return _engine.encrypt(dat, _key);
		}
		else
		{
			update(dat);
			return data();
		}
	}
}
/// ditto
alias AES256CBCEncrypter = Encrypter!DefaultAES256CBCEncryptEngine;

// AES256CBC Encrypt for OpenSSL
static if (enableOpenSSLEngines) @system unittest
{
	auto key = cast(immutable(ubyte)[])"0123456789ABCDEF0123456789ABCDEF";
	auto iv = cast(immutable(ubyte)[])"0123456789ABCDEF";
	auto enc = Encrypter!OpenSSLAES256CBCEncryptEngine(key, iv);
	enc.update(cast(ubyte[])"Hello");
	enc.update(cast(ubyte[])", World!");
	assert(enc.data == x"D326AEF69B8B37F21276C2E1DCE0D750");
	enc = Encrypter!OpenSSLAES256CBCEncryptEngine(key, iv);
	enc.update(cast(ubyte[])"Hello, World!");
	enc.update(cast(ubyte[])"Hello, World! Hello, World!");
	enc.update(cast(ubyte[])"Hello, World!");
	assert(enc.data == x"5331710676FF966EB2A6DC185BE60BED10D1E288A2B5EC75CA0E78F4422809E0"
		~ x"979CE7F69DA3C7171B0ADE10D456A63BB48CA033BEAA27D8E49EE1CBA03D064C");
}
// AES256CBC Encrypt for Windows
static if (enableBcryptEngines) @system unittest
{
	auto key = cast(immutable(ubyte)[])"0123456789ABCDEF0123456789ABCDEF";
	auto iv = cast(immutable(ubyte)[])"0123456789ABCDEF";
	auto enc = Encrypter!BcryptAES256CBCEncryptEngine(key, iv);
	enc.update(cast(ubyte[])"Hello");
	enc.update(cast(ubyte[])", World!");
	assert(enc.data == x"D326AEF69B8B37F21276C2E1DCE0D750");
	enc = Encrypter!BcryptAES256CBCEncryptEngine(key, iv);
	enc.update(cast(ubyte[])"Hello, World!");
	enc.update(cast(ubyte[])"Hello, World! Hello, World!");
	enc.update(cast(ubyte[])"Hello, World!");
	assert(enc.data == x"5331710676FF966EB2A6DC185BE60BED10D1E288A2B5EC75CA0E78F4422809E0"
		~ x"979CE7F69DA3C7171B0ADE10D456A63BB48CA033BEAA27D8E49EE1CBA03D064C");
}
// AES256CBC Encrypt for OpenSSL Command line
static if (enableOpenSSLCmdEngines) @system unittest
{
	if (!isCommandExisting(defaultOpenSSLCommand))
		return;
	auto key = cast(immutable(ubyte)[])"0123456789ABCDEF0123456789ABCDEF";
	auto iv = cast(immutable(ubyte)[])"0123456789ABCDEF";
	
	auto enc = Encrypter!OpenSSLCmdAES256CBCEncryptEngine(key, iv);
	enc.update(cast(ubyte[])"Hello");
	enc.update(cast(ubyte[])", World!");
	assert(enc.data == x"D326AEF69B8B37F21276C2E1DCE0D750");
	enc = Encrypter!OpenSSLCmdAES256CBCEncryptEngine(key, iv);
	enc.update(cast(ubyte[])"Hello, World!");
	enc.update(cast(ubyte[])"Hello, World! Hello, World!");
	enc.update(cast(ubyte[])"Hello, World!");
	assert(enc.data == x"5331710676FF966EB2A6DC185BE60BED10D1E288A2B5EC75CA0E78F4422809E0"
		~ x"979CE7F69DA3C7171B0ADE10D456A63BB48CA033BEAA27D8E49EE1CBA03D064C");
}

/*******************************************************************************
 * Decrypt
 */
struct Decrypter(Engine)
{
private:
	Engine _engine;
	static if (isRSAEngine!Engine)
	{
		enum _onlyOneShot = true;
		Engine.PrivateKey _key;
	}
	else
	{
		enum _onlyOneShot = false;
		Appender!(immutable(ubyte)[]) _dst;
	}
	enum bool _requireCommand = isOpenSSLCmdEngine!Engine;
	bool _padding;
	bool _finalized;
public:
	/***************************************************************************
	 * Constructor
	 */
	this(Engine engine, bool padding = true)
	{
		_engine = engine.move;
		static if (!_onlyOneShot)
			_dst = appender!(immutable(ubyte)[])();
		_padding = padding;
		_finalized = false;
	}
	/// ditto
	static if (_requireCommand && isAESEngine!Engine)
	this(immutable(ubyte)[] key, immutable(ubyte)[] iv, bool padding = true, string cmd = defaultOpenSSLCommand)
	{
		this(Engine(key, iv, cmd), padding);
	}
	/// ditto
	static if (!_requireCommand && isAESEngine!Engine)
	this(immutable(ubyte)[] key, immutable(ubyte)[] iv, bool padding = true)
	{
		this(Engine(key, iv), padding);
	}
	/// ditto
	static if (_requireCommand && isRSAEngine!Engine)
	this(string pubKey, bool padding = true, string cmd = defaultOpenSSLCommand)
	{
		_key = Engine.PrivateKey.fromPEM(pubKey);
		this(Engine(cmd), padding);
	}
	/// ditto
	static if (_requireCommand && isRSAEngine!Engine)
	this(immutable(ubyte)[] prvKey, bool padding = true, string cmd = defaultOpenSSLCommand)
	{
		_key = Engine.PrivateKey.fromDER(prvKey);
		this(Engine(cmd), padding);
	}
	/// ditto
	static if (_requireCommand && isRSAEngine!Engine)
	this(size_t N)(immutable(ubyte)[N] prvKey, bool padding = true, string cmd = defaultOpenSSLCommand)
	{
		_key = Engine.PrivateKey.fromBinary(prvKey);
		this(Engine(cmd), padding);
	}
	/// ditto
	static if (!_requireCommand && isRSAEngine!Engine)
	this(string prvKey, bool padding = true)
	{
		_key = Engine.PrivateKey.fromPEM(prvKey);
		this(Engine(), padding);
	}
	/// ditto
	static if (!_requireCommand && isRSAEngine!Engine)
	this(immutable(ubyte)[] prvKey, bool padding = true)
	{
		_key = Engine.PrivateKey.fromDER(prvKey);
		this(Engine(), padding);
	}
	/// ditto
	static if (!_requireCommand && isRSAEngine!Engine)
	this(size_t N)(immutable(ubyte)[N] prvKey, bool padding = true)
	{
		_key = Engine.PrivateKey.fromBinary(prvKey);
		this(Engine(), padding);
	}
	/***************************************************************************
	 * Update
	 */
	static if (!_onlyOneShot)
	void update(in ubyte[] data)
	in (!_finalized)
	{
		_engine.update(data, _dst);
	}
	/***************************************************************************
	 * Data
	 */
	static if (!_onlyOneShot)
	immutable(ubyte)[] data()
	{
		if (!_finalized)
		{
			_engine.finalize(_dst, _padding);
			_finalized = true;
		}
		return _dst.data();
	}
	/***************************************************************************
	 * OneShot decrypt
	 */
	immutable(ubyte)[] decrypt(in ubyte[] dat)
	{
		static if (_onlyOneShot)
		{
			return _engine.decrypt(dat, _key);
		}
		else
		{
			update(dat);
			return data();
		}
	}
}
/// ditto
alias AES256CBCDecrypter = Decrypter!DefaultAES256CBCDecryptEngine;
/// ditto
alias RSA4096Decrypter = Decrypter!DefaultRSA4096Engine;

// AES256CBC Encrypt/Decrypt for OpenSSL
static if (enableOpenSSLEngines) @system unittest
{
	auto key = cast(immutable(ubyte)[])"0123456789ABCDEF0123456789ABCDEF";
	auto iv = cast(immutable(ubyte)[])"0123456789ABCDEF";
	auto dec = Decrypter!OpenSSLAES256CBCDecryptEngine(key, iv);
	dec.update(x"D326");
	dec.update(x"AEF69B8B");
	dec.update(x"37F21276C2E1DCE0D750");
	assert(dec.data == cast(ubyte[])"Hello, World!");
	dec = Decrypter!OpenSSLAES256CBCDecryptEngine(key, iv);
	dec.update(x"5331710676FF966EB2A6DC185BE60BED10D1E288A2B5EC75CA0E78F4422809E0");
	dec.update(x"979CE7F69DA3C7171B0ADE10D456A63BB48C");
	dec.update(x"A033BEAA27D8E49EE1CBA03D064C");
	assert(cast(string)dec.data == "Hello, World!Hello, World! Hello, World!Hello, World!");
}
// AES256CBC Encrypt/Decrypt for Bcrypt
static if (enableBcryptEngines) @system unittest
{
	auto key = cast(immutable(ubyte)[])"0123456789ABCDEF0123456789ABCDEF";
	auto iv = cast(immutable(ubyte)[])"0123456789ABCDEF";
	auto dec = Decrypter!BcryptAES256CBCDecryptEngine(key, iv);
	dec.update(x"D326");
	dec.update(x"AEF69B8B");
	dec.update(x"37F21276C2E1DCE0D750");
	assert(dec.data == cast(ubyte[])"Hello, World!");
	dec = Decrypter!BcryptAES256CBCDecryptEngine(key, iv);
	dec.update(x"5331710676FF966EB2A6DC185BE60BED10D1E288A2B5EC75CA0E78F4422809E0");
	dec.update(x"979CE7F69DA3C7171B0ADE10D456A63BB48C");
	dec.update(x"A033BEAA27D8E49EE1CBA03D064C");
	assert(cast(string)dec.data == "Hello, World!Hello, World! Hello, World!Hello, World!");
}
// AES256CBC Encrypt/Decrypt for OpenSSL Command line
static if (enableOpenSSLCmdEngines) @system unittest
{
	if (!isCommandExisting(defaultOpenSSLCommand))
		return;
	auto key = cast(immutable(ubyte)[])"0123456789ABCDEF0123456789ABCDEF";
	auto iv = cast(immutable(ubyte)[])"0123456789ABCDEF";
	auto dec = Decrypter!OpenSSLCmdAES256CBCDecryptEngine(key, iv);
	dec.update(x"D326");
	dec.update(x"AEF69B8B");
	dec.update(x"37F21276C2E1DCE0D750");
	assert(dec.data == cast(ubyte[])"Hello, World!");
	dec = Decrypter!OpenSSLCmdAES256CBCDecryptEngine(key, iv);
	dec.update(x"5331710676FF966EB2A6DC185BE60BED10D1E288A2B5EC75CA0E78F4422809E0");
	dec.update(x"979CE7F69DA3C7171B0ADE10D456A63BB48C");
	dec.update(x"A033BEAA27D8E49EE1CBA03D064C");
	assert(cast(string)dec.data == "Hello, World!Hello, World! Hello, World!Hello, World!");
}

/*******************************************************************************
 * Sign
 */
struct Signer(Engine, DigestEngine = void)
{
private:
	Engine _engine;
	static if (is(DigestEngine == void))
	{
		Appender!bin_t _message;
	}
	else
	{
		DigestEngine _digest;
	}
	Engine.PrivateKey _prvKey;
public:
	~this() @trusted
	{
		_prvKey.move();
	}
	/***************************************************************************
	 * Constructor
	 */
	this(Engine engine, Engine.PrivateKey prvKey) @trusted
	{
		_engine = engine.move();
		_prvKey = prvKey.move();
		static if (is(DigestEngine == void))
			_message = appender!bin_t;
		else
			_digest.start();
	}
	/// ditto
	static if (isOpenSSLCmdEngine!Engine)
	this(in char[] prvKeyPEM, string cmd = defaultOpenSSLCommand) @trusted
	{
		this(Engine(cmd), Engine.PrivateKey.fromPEM(prvKeyPEM));
	}
	/// ditto
	static if (isOpenSSLCmdEngine!Engine)
	this(in ubyte[] prvKeyDER, string cmd = defaultOpenSSLCommand) @trusted
	{
		this(Engine(cmd), Engine.PrivateKey.fromDER(prvKeyDER));
	}
	/// ditto
	static if (isOpenSSLCmdEngine!Engine)
	this(in BinaryKey!(Engine.prvKeyLen) prvKeyRaw, string cmd = defaultOpenSSLCommand) @trusted
	{
		this(Engine(cmd), Engine.PrivateKey.fromBinary(prvKeyRaw));
	}
	/// ditto
	static if (!isOpenSSLCmdEngine!Engine)
	this(in char[] prvKeyPEM) @trusted
	{
		this(Engine(), Engine.PrivateKey.fromPEM(prvKeyPEM));
	}
	/// ditto
	static if (!isOpenSSLCmdEngine!Engine)
	this(in ubyte[] prvKeyDER) @trusted
	{
		this(Engine(), Engine.PrivateKey.fromDER(prvKeyDER));
	}
	/// ditto
	static if (!isOpenSSLCmdEngine!Engine)
	this(in BinaryKey!(Engine.prvKeyLen) prvKeyRaw) @trusted
	{
		this(Engine(), Engine.PrivateKey.fromBinary(prvKeyRaw));
	}
	/***************************************************************************
	 * Update
	 */
	void update(in ubyte[] message) @safe
	{
		static if (is(DigestEngine == void))
		{
			_message.put(message);
		}
		else
		{
			_digest.put(message);
		}
	}
	/***************************************************************************
	 * Sign
	 */
	bin_t sign() @trusted
	{
		static if (is(DigestEngine == void))
		{
			return _engine.sign(_message.data, _prvKey);
		}
		else
		{
			// Duplicate internal data
			auto digest = _digest;
			return _engine.sign(_digest.finish[], _prvKey);
		}
	}
	/***************************************************************************
	 * Sign
	 */
	bin_t sign(in ubyte[] data) @trusted
	{
		static if (is(DigestEngine == void))
		{
			return _engine.sign(data, _prvKey);
		}
		else
		{
			DigestEngine digest;
			digest.put(data);
			return _engine.sign(digest.finish[], _prvKey);
		}
	}
}
/// ditto
alias Ed25519Signer(DigestEngine = void) = Signer!(DefaultEd25519Engine, DigestEngine);
/// ditto
alias Ed25519phSigner = Ed25519Signer!SHA512;
/// ditto
alias ECDSAP256Signer(DigestEngine = void) = Signer!(DefaultECDSAP256Engine, DigestEngine);
/// ditto
alias ECDSAP256KSigner(DigestEngine = void) = Signer!(DefaultECDSAP256KEngine, DigestEngine);
/// ditto
alias ECDSAP384Signer(DigestEngine = void) = Signer!(DefaultECDSAP384Engine, DigestEngine);
/// ditto
alias ECDSAP521Signer(DigestEngine = void) = Signer!(DefaultECDSAP521Engine, DigestEngine);
/// ditto
alias RSA4096Signer(DigestEngine = void) = Signer!(DefaultRSA4096Engine, DigestEngine);


/*******************************************************************************
 * Vefiry
 */
struct Verifier(Engine, DigestEngine = void)
{
private:
	Engine _engine;
	static if (is(DigestEngine == void))
	{
		Appender!bin_t _message;
	}
	else
	{
		DigestEngine _digest;
	}
	Engine.PublicKey _pubKey;
public:
	/***************************************************************************
	 * Constructor
	 */
	this(Engine engine, Engine.PublicKey pubKey) @trusted
	{
		_engine = engine.move;
		_pubKey = pubKey.move;
		static if (!is(DigestEngine == void))
			_digest.start();
	}
	/// ditto
	static if (isOpenSSLCmdEngine!Engine)
	this(in char[] pubKeyPEM, string cmd = defaultOpenSSLCommand) @trusted
	{
		this(Engine(cmd), Engine.PublicKey.fromPEM(pubKeyPEM));
	}
	/// ditto
	static if (isOpenSSLCmdEngine!Engine)
	this(in ubyte[] pubKeyDER, string cmd = defaultOpenSSLCommand) @trusted
	{
		this(Engine(cmd), Engine.PublicKey.fromDER(pubKeyDER));
	}
	/// ditto
	static if (isOpenSSLCmdEngine!Engine)
	this(in BinaryKey!(Engine.pubKeyLen) pubKeyRaw, string cmd = defaultOpenSSLCommand) @trusted
	{
		this(Engine(cmd), Engine.PublicKey.fromBinary(pubKeyRaw));
	}
	/// ditto
	static if (!isOpenSSLCmdEngine!Engine)
	this(in char[] pubKeyPEM) @trusted
	{
		this(Engine(), Engine.PublicKey.fromPEM(pubKeyPEM));
	}
	/// ditto
	static if (!isOpenSSLCmdEngine!Engine)
	this(in ubyte[] pubKeyDER) @trusted
	{
		this(Engine(), Engine.PublicKey.fromDER(pubKeyDER));
	}
	/// ditto
	static if (!isOpenSSLCmdEngine!Engine)
	this(in BinaryKey!(Engine.pubKeyLen) pubKeyRaw) @trusted
	{
		this(Engine(), Engine.PublicKey.fromBinary(pubKeyRaw));
	}
	/***************************************************************************
	 * Update
	 */
	void update(in ubyte[] message) @safe
	{
		static if (is(DigestEngine == void))
		{
			_message.put(message);
		}
		else
		{
			_digest.put(message);
		}
	}
	/***************************************************************************
	 * Verify
	 */
	bool verify(in ubyte[] signature) @trusted
	{
		static if (is(DigestEngine == void))
		{
			return _engine.verify(_message.data, signature, _pubKey);
		}
		else
		{
			// Duplicate internal data
			auto digest = _digest;
			return _engine.verify(digest.finish[], signature, _pubKey);
		}
	}
	/// ditto
	bool verify(in ubyte[] signature, in ubyte[] message) @trusted
	{
		static if (is(DigestEngine == void))
		{
			return _engine.verify(message, signature, _pubKey);
		}
		else
		{
			// Duplicate internal data
			DigestEngine digest;
			digest.put(message);
			return _engine.verify(digest.finish[], signature, _pubKey);
		}
	}
}
/// ditto
alias Ed25519Verifier(DigestEngine = void) = Verifier!(DefaultEd25519Engine, DigestEngine);
/// ditto
alias Ed25519phVerifier = Ed25519Verifier!SHA512;
/// ditto
alias ECDSAP256Verifier(DigestEngine = void) = Verifier!(DefaultECDSAP256Engine, DigestEngine);
/// ditto
alias ECDSAP256KVerifier(DigestEngine = void) = Verifier!(DefaultECDSAP256KEngine, DigestEngine);
/// ditto
alias ECDSAP384Verifier(DigestEngine = void) = Verifier!(DefaultECDSAP384Engine, DigestEngine);
/// ditto
alias ECDSAP521Verifier(DigestEngine = void) = Verifier!(DefaultECDSAP521Engine, DigestEngine);
/// ditto
alias RSA4096Verifier(DigestEngine = void) = Verifier!(DefaultRSA4096Engine, DigestEngine);

// Ed25519 Sign/Verify
static if (enableOpenSSLEngines) @system unittest
{
	auto prvKey = OpenSSLEd25519Engine.PrivateKey.createKey();
	auto pubKey = OpenSSLEd25519Engine.PublicKey.createKey(prvKey);
	auto signer = Signer!OpenSSLEd25519Engine(prvKey.toPEM);
	auto message = "Hello, World!";
	signer.update(message.representation);
	auto signature = signer.sign();
	auto verifier = Verifier!OpenSSLEd25519Engine(pubKey.toPEM);
	verifier.update(message.representation);
	auto result = verifier.verify(signature);
	assert(result);
}
// Ed25519 Sign/Verify
static if (enableOpenSSLEngines) @system unittest
{
	auto prvKey = OpenSSLEd25519Engine.PrivateKey.fromBinary(
		x"6BD57B7C2FDA227E75C30F02590D63F3CFC26E6DA59024C305E5044BE21CF632");
	auto pubKey = OpenSSLEd25519Engine.PublicKey.fromBinary(
		x"35E386C088F7709C010EB0FC24C8BF88228B3D66D29EE7E21E72C74EB73B56E9");
	assert(prvKey.toPEM.pem2der[$-32..$] == x"6BD57B7C2FDA227E75C30F02590D63F3CFC26E6DA59024C305E5044BE21CF632");
	assert(pubKey.toPEM.pem2der[$-32..$] == x"35E386C088F7709C010EB0FC24C8BF88228B3D66D29EE7E21E72C74EB73B56E9");
	auto signer = Signer!OpenSSLEd25519Engine(prvKey.toDER);
	auto message = "Hello, World!";
	signer.update(message.representation);
	auto signature = signer.sign();
	assert(signature == x"90DF153EA4A501685E8EC9A4DE3BE6EB66631406BB5F0F76643E38DEB131952A"
		~x"896D30E48F99ACB33A1D507CFCFC2CC0C2BA4EAE1BD7ACF0E9CC029163CF6D07");
	auto verifier = Verifier!OpenSSLEd25519Engine(pubKey.toDER);
	verifier.update(message.representation);
	assert(verifier.verify(signature));
	
	auto signer2 = Signer!(OpenSSLEd25519Engine, SHA256)(prvKey.toBinary);
	signer2.update(message.representation);
	auto signature2 = signer2.sign();
	assert(signature2 == x"747517CAC151B4A297BCDCDBF89DF00E948BD080ADE394CBAF2646F441915F13"
		~x"C64530BB3D26DE0BC150B65FD87FCDAC9EA372A4015945A2CAF2AB16AA098B08");
	auto verifier2 = Verifier!(OpenSSLEd25519Engine, SHA256)(pubKey.toBinary);
	verifier2.update(message.representation);
	assert(verifier2.verify(signature2));
}
// Ed25519 Sign/Verify for OpenSSL Command line
static if (enableOpenSSLCmdEngines) @system unittest
{
	if (!isCommandExisting(defaultOpenSSLCommand))
		return;
	if (getOpenSSLCmdVerseion(defaultOpenSSLCommand) < SemVer(3, 1, 1))
		return;
	auto prvKey = OpenSSLCmdEd25519Engine.PrivateKey.createKey();
	auto pubKey = OpenSSLCmdEd25519Engine.PublicKey.createKey(prvKey);
	auto signer = Signer!OpenSSLCmdEd25519Engine(prvKey.toBinary);
	enum message = cast(immutable ubyte[])"Hello, World!";
	signer.update(message);
	auto signature = signer.sign;
	auto verifier = Verifier!OpenSSLCmdEd25519Engine(pubKey.toBinary);
	verifier.update(message);
	assert(verifier.verify(signature));
}
// Ed25519 Sign/Verify for OpenSSL Command line
static if (enableOpenSSLCmdEngines) @system unittest
{
	if (!isCommandExisting(defaultOpenSSLCommand))
		return;
	if (getOpenSSLCmdVerseion(defaultOpenSSLCommand) < SemVer(3, 0, 1))
		return;
	auto prvKey = OpenSSLCmdEd25519Engine.PrivateKey.fromBinary(
		x"6BD57B7C2FDA227E75C30F02590D63F3CFC26E6DA59024C305E5044BE21CF632");
	auto pubKey = OpenSSLCmdEd25519Engine.PublicKey.fromBinary(
		x"35E386C088F7709C010EB0FC24C8BF88228B3D66D29EE7E21E72C74EB73B56E9");
	assert(prvKey.toPEM.pem2der[$-32..$] == x"6BD57B7C2FDA227E75C30F02590D63F3CFC26E6DA59024C305E5044BE21CF632");
	assert(pubKey.toPEM.pem2der[$-32..$] == x"35E386C088F7709C010EB0FC24C8BF88228B3D66D29EE7E21E72C74EB73B56E9");
	auto signer = Signer!OpenSSLCmdEd25519Engine(prvKey.toDER);
	auto message = "Hello, World!";
	signer.update(message.representation);
	auto signature = signer.sign();
	assert(signature == x"90DF153EA4A501685E8EC9A4DE3BE6EB66631406BB5F0F76643E38DEB131952A"
		~x"896D30E48F99ACB33A1D507CFCFC2CC0C2BA4EAE1BD7ACF0E9CC029163CF6D07");
	auto verifier = Verifier!OpenSSLCmdEd25519Engine(pubKey.toDER);
	verifier.update(message.representation);
	assert(verifier.verify(signature));
}
// ECDSA P256 Sign/Verify for Window
static if (enableBcryptEngines) @system unittest
{
	import std.string;
	enum prvKeyBin = cast(immutable(ubyte)[32])x"8ba5532db91d5e2f3d188f5e4b23c36223ecb14da4f10ac21b68f2274dfc1689";
	enum pubKeyBin = cast(immutable(ubyte)[65])(x"048fa35f141d8d817f6130c068ad1a519bf6d13dfef693fae66c139a3a9c703229"
		~ x"1f7bfa8b54cf9ad76929fd5c309b750af53766d261be82a1e3dec831102feabf");
	// openssl ecparam -name prime256v1 -genkey -noout -out private_key.pem
	enum prvKeyPem = ""
		~ "-----BEGIN EC PRIVATE KEY-----\r\n"
		~ "MHcCAQEEIIulUy25HV4vPRiPXksjw2Ij7LFNpPEKwhto8idN/BaJoAoGCCqGSM49\r\n"
		~ "AwEHoUQDQgAEj6NfFB2NgX9hMMBorRpRm/bRPf72k/rmbBOaOpxwMikfe/qLVM+a\r\n"
		~ "12kp/Vwwm3UK9Tdm0mG+gqHj3sgxEC/qvw==\r\n"
		~ "-----END EC PRIVATE KEY-----\r\n";
	enum prvKeyDer = cast(immutable(ubyte)[])(x"30770201010420"
		~ x"8BA5532DB91D5E2F3D188F5E4B23C36223ECB14DA4F10AC21B68F2274DFC1689"
		~ x"A00A06082A8648CE3D030107A144034200"
		~ x"048FA35F141D8D817F6130C068AD1A519BF6D13DFEF693FAE66C139A3A9C703229"
		~ x"1F7BFA8B54CF9AD76929FD5C309B750AF53766D261BE82A1E3DEC831102FEABF");
	enum pubKeyPem = ""
		~ "-----BEGIN PUBLIC KEY-----\r\n"
		~ "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEj6NfFB2NgX9hMMBorRpRm/bRPf72\r\n"
		~ "k/rmbBOaOpxwMikfe/qLVM+a12kp/Vwwm3UK9Tdm0mG+gqHj3sgxEC/qvw==\r\n"
		~ "-----END PUBLIC KEY-----\r\n";
	enum pubKeyDer = cast(immutable(ubyte)[])(x"3059301306072A8648CE3D020106082A8648CE3D030107034200"
		~ x"048FA35F141D8D817F6130C068AD1A519BF6D13DFEF693FAE66C139A3A9C703229"
		~ x"1F7BFA8B54CF9AD76929FD5C309B750AF53766D261BE82A1E3DEC831102FEABF");
	// openssl pkeyutl -sign -inkey private_key.pem -in test.txt -out signature.bin
	enum signatureExample1 = cast(immutable(ubyte)[])(x""
		~ x"e8f9430f24d17213479d541e44dff2a265c8a0a062753b5e11c2774f9219e0b4"
		~ x"30ce2856ff6d2f44228cb9765b0199543aa4cbc58953e8b97feac6fb426cb7ab");
	// from OpenSSLECDSAP256Engine
	enum signatureExample2 = cast(immutable(ubyte)[])(x""
		~ x"3C08FAFB8E248C53BCE02E37B0C150DF4C4B1E05EF6D7A6786CCD472950FE203"
		~ x"CBBF4B97B5C59B7A4B8B275D481E618C5A5874FB1A8C94A477A99A61085BEBF9");
	// openssl dgst -sha256 -sign private_key.pem -out signature.bin test.txt
	enum signaturePhSHA256Example1 = cast(immutable(ubyte)[])(x""
		~ x"841AB8FFD0D42C50985C7FC1DE88B3FA5D817089C779E3F36D9630EFC3CF39AB"
		~ x"365E93430E6FEFA1B3970380BF079428AFF5CBFA9E699BD2092921AAEAD70889");
	// from OpenSSLECDSAP256Engine
	enum signaturePhSHA256Example2 = cast(immutable(ubyte)[])(x""
		~ x"792D01D50A89328DF5733F2A312BCB98AFDBD295A442DED5633FA1351F5D6089"
		~ x"D0D381F2E29BE8B232746F78F7310035E499DA2A3E71D4A2FD6798AE81589289");
	auto prvKey = BcryptECDSAP256Engine.PrivateKey.fromBinary(prvKeyBin);
	auto pubKey = BcryptECDSAP256Engine.PublicKey.fromBinary(pubKeyBin);
	assert(prvKey.toBinary == prvKeyBin);
	assert(pubKey.toBinary == pubKeyBin);
	auto prvKey2 = BcryptECDSAP256Engine.PrivateKey.fromPEM(prvKeyPem);
	assert(prvKey.toPEM.splitLines == prvKeyPem.splitLines);
	assert(prvKey2.toPEM.splitLines == prvKeyPem.splitLines);
	
	auto prvKey3 = BcryptECDSAP256Engine.PrivateKey.fromDER(prvKeyDer);
	assert(prvKey.toDER == prvKeyDer);
	assert(prvKey.toDER.der2pem("EC PRIVATE KEY").splitLines == prvKeyPem.splitLines);
	assert(prvKey.toDER == prvKey3.toDER);
	
	auto pubKey2 = BcryptECDSAP256Engine.PublicKey.fromPEM(pubKeyPem);
	assert(pubKey.toPEM.splitLines == pubKeyPem.splitLines);
	assert(pubKey2.toPEM.splitLines == pubKeyPem.splitLines);
	assert(pubKey.toDER.der2pem("PUBLIC KEY").splitLines == pubKeyPem.splitLines);
	
	auto pubKey3 = BcryptECDSAP256Engine.PublicKey.fromDER(pubKeyDer);
	assert(pubKey.toDER == pubKeyDer);
	assert(pubKey.toBinary == pubKey3.toBinary);
	
	auto signer = Signer!BcryptECDSAP256Engine(prvKey.toBinary);
	auto message = "Hello, World!";
	signer.update(message.representation);
	auto signature = signer.sign();
	
	auto verifier = Verifier!BcryptECDSAP256Engine(pubKey.toDER);
	verifier.update(message.representation);
	assert(verifier.verify(signature));
	assert(verifier.verify(signatureExample1));
	assert(verifier.verify(signatureExample2));
	
	auto signer2 = Signer!(BcryptECDSAP256Engine, SHA256)(prvKey.toBinary);
	signer2.update(message.representation);
	auto signature2 = signer2.sign();
	
	auto verifier2 = Verifier!(BcryptECDSAP256Engine, SHA256)(pubKey.toBinary);
	verifier2.update(message.representation);
	assert(verifier2.verify(signature2));
	assert(verifier2.verify(signaturePhSHA256Example1));
	assert(verifier2.verify(signaturePhSHA256Example2));
}
// ECDSA P256 Sign/Verify for OpenSSL
static if (enableOpenSSLEngines) @system unittest
{
	import std.string;
	enum prvKeyBin = cast(immutable(ubyte)[32])x"8ba5532db91d5e2f3d188f5e4b23c36223ecb14da4f10ac21b68f2274dfc1689";
	enum pubKeyBin = cast(immutable(ubyte)[65])(x"048fa35f141d8d817f6130c068ad1a519bf6d13dfef693fae66c139a3a9c703229"
		~ x"1f7bfa8b54cf9ad76929fd5c309b750af53766d261be82a1e3dec831102feabf");
	// openssl ecparam -name prime256v1 -genkey -noout -out private_key.pem
	enum prvKeyPem = ""
		~ "-----BEGIN EC PRIVATE KEY-----\r\n"
		~ "MHcCAQEEIIulUy25HV4vPRiPXksjw2Ij7LFNpPEKwhto8idN/BaJoAoGCCqGSM49\r\n"
		~ "AwEHoUQDQgAEj6NfFB2NgX9hMMBorRpRm/bRPf72k/rmbBOaOpxwMikfe/qLVM+a\r\n"
		~ "12kp/Vwwm3UK9Tdm0mG+gqHj3sgxEC/qvw==\r\n"
		~ "-----END EC PRIVATE KEY-----\r\n";
	enum prvKeyDer = cast(immutable(ubyte)[])(x"30770201010420"
		~ x"8BA5532DB91D5E2F3D188F5E4B23C36223ECB14DA4F10AC21B68F2274DFC1689"
		~ x"A00A06082A8648CE3D030107A144034200"
		~ x"048FA35F141D8D817F6130C068AD1A519BF6D13DFEF693FAE66C139A3A9C703229"
		~ x"1F7BFA8B54CF9AD76929FD5C309B750AF53766D261BE82A1E3DEC831102FEABF");
	enum pubKeyPem = ""
		~ "-----BEGIN PUBLIC KEY-----\r\n"
		~ "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEj6NfFB2NgX9hMMBorRpRm/bRPf72\r\n"
		~ "k/rmbBOaOpxwMikfe/qLVM+a12kp/Vwwm3UK9Tdm0mG+gqHj3sgxEC/qvw==\r\n"
		~ "-----END PUBLIC KEY-----\r\n";
	enum pubKeyDer = cast(immutable(ubyte)[])(x"3059301306072A8648CE3D020106082A8648CE3D030107034200"
		~ x"048FA35F141D8D817F6130C068AD1A519BF6D13DFEF693FAE66C139A3A9C703229"
		~ x"1F7BFA8B54CF9AD76929FD5C309B750AF53766D261BE82A1E3DEC831102FEABF");
	// openssl pkeyutl -sign -inkey private_key.pem -in test.txt -out signature.bin
	enum signatureExample1 = cast(immutable(ubyte)[])(x""
		~ x"e8f9430f24d17213479d541e44dff2a265c8a0a062753b5e11c2774f9219e0b4"
		~ x"30ce2856ff6d2f44228cb9765b0199543aa4cbc58953e8b97feac6fb426cb7ab");
	enum signatureExample2 = cast(immutable(ubyte)[])(x""
		~ x"3C08FAFB8E248C53BCE02E37B0C150DF4C4B1E05EF6D7A6786CCD472950FE203"
		~ x"CBBF4B97B5C59B7A4B8B275D481E618C5A5874FB1A8C94A477A99A61085BEBF9");
	// openssl dgst -sha256 -sign private_key.pem -out signature.bin test.txt
	enum signaturePhSHA256Example1 = cast(immutable(ubyte)[])(x""
		~ x"841AB8FFD0D42C50985C7FC1DE88B3FA5D817089C779E3F36D9630EFC3CF39AB"
		~ x"365E93430E6FEFA1B3970380BF079428AFF5CBFA9E699BD2092921AAEAD70889");
	enum signaturePhSHA256Example2 = cast(immutable(ubyte)[])(x""
		~ x"792D01D50A89328DF5733F2A312BCB98AFDBD295A442DED5633FA1351F5D6089"
		~ x"D0D381F2E29BE8B232746F78F7310035E499DA2A3E71D4A2FD6798AE81589289");
	auto prvKey = OpenSSLECDSAP256Engine.PrivateKey.fromBinary(prvKeyBin);
	auto pubKey = OpenSSLECDSAP256Engine.PublicKey.createKey(prvKey);
	assert(prvKey.toBinary == prvKeyBin);
	assert(pubKey.toBinary == pubKeyBin);
	auto prvKey2 = OpenSSLECDSAP256Engine.PrivateKey.fromPEM(prvKeyPem);
	assert(prvKey.toPEM.splitLines == prvKeyPem.splitLines);
	assert(prvKey2.toPEM.splitLines == prvKeyPem.splitLines);
	
	auto prvKey3 = OpenSSLECDSAP256Engine.PrivateKey.fromDER(prvKeyDer);
	assert(prvKey.toDER == prvKeyDer);
	assert(prvKey.toDER.der2pem("EC PRIVATE KEY").splitLines == prvKeyPem.splitLines);
	assert(prvKey.toDER == prvKey3.toDER);
	
	auto pubKey2 = OpenSSLECDSAP256Engine.PublicKey.fromPEM(pubKeyPem);
	assert(pubKey.toPEM.splitLines == pubKeyPem.splitLines);
	assert(pubKey2.toPEM.splitLines == pubKeyPem.splitLines);
	assert(pubKey.toDER.der2pem("PUBLIC KEY").splitLines == pubKeyPem.splitLines);
	
	auto pubKey3 = OpenSSLECDSAP256Engine.PublicKey.fromDER(pubKeyDer);
	assert(pubKey.toDER == pubKeyDer);
	assert(pubKey.toBinary == pubKey3.toBinary);
	
	auto signer = Signer!OpenSSLECDSAP256Engine(prvKey.toBinary);
	auto message = "Hello, World!";
	signer.update(message.representation);
	auto signature = signer.sign();
	
	auto verifier = Verifier!OpenSSLECDSAP256Engine(pubKey.toBinary);
	verifier.update(message.representation);
	assert(verifier.verify(signature));
	assert(verifier.verify(signatureExample1));
	assert(verifier.verify(signatureExample2));
	
	auto signer2 = Signer!(OpenSSLECDSAP256Engine, SHA256)(prvKey.toBinary);
	signer2.update(message.representation);
	auto signature2 = signer2.sign();
	
	auto verifier2 = Verifier!(OpenSSLECDSAP256Engine, SHA256)(pubKey.toBinary);
	verifier2.update(message.representation);
	assert(verifier2.verify(signature2));
	assert(verifier2.verify(signaturePhSHA256Example1));
	assert(verifier2.verify(signaturePhSHA256Example2));
}
// ECDSA P256 Sign/Verify for OpenSSL Command line
static if (enableOpenSSLCmdEngines) @system unittest
{
	if (!isCommandExisting(defaultOpenSSLCommand))
		return;
	import std.string;
	// openssl ecparam -name prime256v1 -genkey -noout -out private_key.pem
	enum prvKeyBin = cast(immutable(ubyte)[32])x"8ba5532db91d5e2f3d188f5e4b23c36223ecb14da4f10ac21b68f2274dfc1689";
	enum pubKeyBin = cast(immutable(ubyte)[65])(x"048fa35f141d8d817f6130c068ad1a519bf6d13dfef693fae66c139a3a9c703229"
		~ x"1f7bfa8b54cf9ad76929fd5c309b750af53766d261be82a1e3dec831102feabf");
	enum prvKeyPem = ""
		~ "-----BEGIN EC PRIVATE KEY-----\r\n"
		~ "MHcCAQEEIIulUy25HV4vPRiPXksjw2Ij7LFNpPEKwhto8idN/BaJoAoGCCqGSM49\r\n"
		~ "AwEHoUQDQgAEj6NfFB2NgX9hMMBorRpRm/bRPf72k/rmbBOaOpxwMikfe/qLVM+a\r\n"
		~ "12kp/Vwwm3UK9Tdm0mG+gqHj3sgxEC/qvw==\r\n"
		~ "-----END EC PRIVATE KEY-----\r\n";
	enum prvKeyDer = cast(immutable(ubyte)[])(x"30770201010420"
		~ x"8BA5532DB91D5E2F3D188F5E4B23C36223ECB14DA4F10AC21B68F2274DFC1689"
		~ x"A00A06082A8648CE3D030107A144034200"
		~ x"048FA35F141D8D817F6130C068AD1A519BF6D13DFEF693FAE66C139A3A9C703229"
		~ x"1F7BFA8B54CF9AD76929FD5C309B750AF53766D261BE82A1E3DEC831102FEABF");
	// openssl ec -in private_key.pem -pubout -out public_key.pem
	enum pubKeyPem = ""
		~ "-----BEGIN PUBLIC KEY-----\r\n"
		~ "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEj6NfFB2NgX9hMMBorRpRm/bRPf72\r\n"
		~ "k/rmbBOaOpxwMikfe/qLVM+a12kp/Vwwm3UK9Tdm0mG+gqHj3sgxEC/qvw==\r\n"
		~ "-----END PUBLIC KEY-----\r\n";
	enum pubKeyDer = cast(immutable(ubyte)[])(x"3059301306072A8648CE3D020106082A8648CE3D030107034200"
		~ x"048FA35F141D8D817F6130C068AD1A519BF6D13DFEF693FAE66C139A3A9C703229"
		~ x"1F7BFA8B54CF9AD76929FD5C309B750AF53766D261BE82A1E3DEC831102FEABF");
	// openssl pkeyutl -sign -inkey private_key.pem -in test.txt -out signature.bin
	enum signatureExample1 = cast(immutable(ubyte)[])(x""
		~ x"e8f9430f24d17213479d541e44dff2a265c8a0a062753b5e11c2774f9219e0b4"
		~ x"30ce2856ff6d2f44228cb9765b0199543aa4cbc58953e8b97feac6fb426cb7ab");
	enum signatureExample2 = cast(immutable(ubyte)[])(x""
		~ x"3C08FAFB8E248C53BCE02E37B0C150DF4C4B1E05EF6D7A6786CCD472950FE203"
		~ x"CBBF4B97B5C59B7A4B8B275D481E618C5A5874FB1A8C94A477A99A61085BEBF9");
	enum signaturePhSHA256Example1 = cast(immutable(ubyte)[])(x""
		~ x"841AB8FFD0D42C50985C7FC1DE88B3FA5D817089C779E3F36D9630EFC3CF39AB"
		~ x"365E93430E6FEFA1B3970380BF079428AFF5CBFA9E699BD2092921AAEAD70889");
	enum signaturePhSHA256Example2 = cast(immutable(ubyte)[])(x""
		~ x"792D01D50A89328DF5733F2A312BCB98AFDBD295A442DED5633FA1351F5D6089"
		~ x"D0D381F2E29BE8B232746F78F7310035E499DA2A3E71D4A2FD6798AE81589289");
	auto prvKey = OpenSSLCmdECDSAP256Engine.PrivateKey.fromPEM(prvKeyPem);
	assert(prvKey.toPEM.splitLines == prvKeyPem.splitLines);
	assert(prvKey.toDER == prvKeyDer);
	assert(prvKey.toBinary == prvKeyBin);
	assert(prvKey.toDER.der2pem("EC PRIVATE KEY").splitLines == prvKeyPem.splitLines);
	assert(prvKey.toPEM.pem2der() == prvKeyDer);
	
	auto prvKey2 = OpenSSLCmdECDSAP256Engine.PrivateKey.fromDER(prvKeyDer);
	assert(prvKey2.toPEM.splitLines == prvKeyPem.splitLines);
	assert(prvKey2.toDER == prvKeyDer);
	assert(prvKey2.toBinary == prvKeyBin);
	
	auto prvKey3 = OpenSSLCmdECDSAP256Engine.PrivateKey.fromBinary(prvKeyBin);
	assert(prvKey3.toPEM.splitLines == prvKeyPem.splitLines);
	assert(prvKey3.toDER == prvKeyDer);
	assert(prvKey3.toBinary == prvKeyBin);
	
	auto pubKey = OpenSSLCmdECDSAP256Engine.PublicKey.fromPEM(pubKeyPem);
	assert(pubKey.toPEM.splitLines == pubKeyPem.splitLines);
	assert(pubKey.toDER == pubKeyDer);
	assert(pubKey.toBinary == pubKeyBin);
	assert(pubKey.toDER.der2pem("PUBLIC KEY").splitLines == pubKeyPem.splitLines);
	assert(pubKey.toPEM.pem2der() == pubKeyDer);
	
	auto pubKey2 = OpenSSLCmdECDSAP256Engine.PublicKey.fromDER(pubKeyDer);
	assert(pubKey2.toPEM.splitLines == pubKeyPem.splitLines);
	assert(pubKey2.toDER == pubKeyDer);
	assert(pubKey2.toBinary == pubKeyBin);
	
	auto pubKey3 = OpenSSLCmdECDSAP256Engine.PublicKey.fromBinary(pubKeyBin);
	assert(pubKey3.toPEM.splitLines == pubKeyPem.splitLines);
	assert(pubKey3.toDER == pubKeyDer);
	assert(pubKey3.toBinary == pubKeyBin);
	
	auto pubKey4 = OpenSSLCmdECDSAP256Engine.PublicKey.createKey(prvKey);
	assert(pubKey4.toPEM.splitLines == pubKeyPem.splitLines);
	assert(pubKey4.toDER == pubKeyDer);
	assert(pubKey4.toBinary == pubKeyBin);
	auto signer = Signer!OpenSSLCmdECDSAP256Engine(prvKey.toBinary);
	auto message = "Hello, World!";
	signer.update(message.representation);
	auto signature = signer.sign();
	
	auto verifier = Verifier!OpenSSLCmdECDSAP256Engine(pubKey.toBinary);
	verifier.update(message.representation);
	assert(verifier.verify(signature));
	assert(verifier.verify(signatureExample1));
	assert(verifier.verify(signatureExample2));
	
	auto signer2 = Signer!(OpenSSLCmdECDSAP256Engine, SHA256)(prvKey.toBinary);
	signer2.update(message.representation);
	auto signature2 = signer2.sign();
	
	auto verifier2 = Verifier!(OpenSSLCmdECDSAP256Engine, SHA256)(pubKey.toBinary);
	verifier2.update(message.representation);
	assert(verifier2.verify(signature2));
	assert(verifier2.verify(signaturePhSHA256Example1));
	assert(verifier2.verify(signaturePhSHA256Example2));
}

// Sign/Verify for Any Engine
@system unittest
{
	alias PrvKeyDer = DERBinary;
	alias PubKeyDer = DERBinary;
	alias SignData  = bin_t;
	PrvKeyDer[][ECDSAType] prvKeyDers;
	PubKeyDer[PrvKeyDer][ECDSAType] pubKeyDers;
	SignData[][PrvKeyDer][ECDSAType] signs;
	enum message = "Hello, World!".representation;
	
	void test1(Engine)()
	{
		// 鍵の生成
		auto prvKey = Engine.PrivateKey.createKey();
		auto pubKey = Engine.PublicKey.createKey(prvKey);
		auto prvKeyDer = prvKey.toDER();
		prvKeyDers[Engine.cipherType] ~= prvKeyDer;
		if (auto pkd = Engine.cipherType in pubKeyDers)
			(*pkd)[prvKeyDer] = pubKey.toDER();
		else
			pubKeyDers[Engine.cipherType] = [prvKeyDer: pubKey.toDER()];
	}
	
	void test2(Engine)()
	{
		// 各エンジンが生成した秘密鍵×各エンジンでの署名
		foreach (prvKeyDer; prvKeyDers[Engine.cipherType])
		{
			auto prvKey = Engine.PrivateKey.fromDER(prvKeyDer);
			if (auto singElm = Engine.cipherType in signs)
				(*singElm)[prvKeyDer] ~= Signer!Engine(prvKeyDer).sign(message);
			else
				signs[Engine.cipherType] = [prvKeyDer: [Signer!Engine(prvKeyDer).sign(message)]];
		}
	}
	
	void test3(Engine)()
	{
		// 各エンジンが生成した秘密鍵×各エンジンで生成した秘密鍵
		foreach (prvKeyDer; prvKeyDers[Engine.cipherType])
		{
			auto prvKey = Engine.PrivateKey.fromDER(prvKeyDer);
			auto pubKey = Engine.PublicKey.createKey(prvKey);
			assert(pubKey.toDER() == pubKeyDers[Engine.cipherType][prvKeyDer]);
		}
		// 各エンジンが生成した署名×各エンジンでの検証
		foreach (prvKeyDer, signlist; signs[Engine.cipherType])
		{
			auto pubKeyDer = pubKeyDers[Engine.cipherType][prvKeyDer];
			foreach (sign; signlist)
				assert(Verifier!Engine(pubKeyDer).verify(sign, message));
		}
	}
	
	static if (enableOpenSSLCmdEngines) if (isCommandExisting(defaultOpenSSLCommand))
	{
		test1!(OpenSSLCmdECDSAEngine!(ECDSAType.p256))();
		test1!(OpenSSLCmdECDSAEngine!(ECDSAType.p256k))();
		test1!(OpenSSLCmdECDSAEngine!(ECDSAType.p384))();
		test1!(OpenSSLCmdECDSAEngine!(ECDSAType.p521))();
	}
	
	static if (enableOpenSSLEngines)
	{
		test1!(OpenSSLECDSAEngine!(ECDSAType.p256))();
		test1!(OpenSSLECDSAEngine!(ECDSAType.p256k))();
		test1!(OpenSSLECDSAEngine!(ECDSAType.p384))();
		test1!(OpenSSLECDSAEngine!(ECDSAType.p521))();
	}
	
	static if (enableBcryptEngines)
	{
		test1!(BcryptECDSAEngine!(ECDSAType.p256))();
		test1!(BcryptECDSAEngine!(ECDSAType.p256k))();
		test1!(BcryptECDSAEngine!(ECDSAType.p384))();
		test1!(BcryptECDSAEngine!(ECDSAType.p521))();
	}
	
	static if (enableOpenSSLCmdEngines) if (isCommandExisting(defaultOpenSSLCommand))
	{
		test2!(OpenSSLCmdECDSAEngine!(ECDSAType.p256))();
		test2!(OpenSSLCmdECDSAEngine!(ECDSAType.p256k))();
		test2!(OpenSSLCmdECDSAEngine!(ECDSAType.p384))();
		test2!(OpenSSLCmdECDSAEngine!(ECDSAType.p521))();
	}
	
	static if (enableOpenSSLEngines)
	{
		test2!(OpenSSLECDSAEngine!(ECDSAType.p256))();
		test2!(OpenSSLECDSAEngine!(ECDSAType.p256k))();
		test2!(OpenSSLECDSAEngine!(ECDSAType.p384))();
		test2!(OpenSSLECDSAEngine!(ECDSAType.p521))();
	}
	
	static if (enableBcryptEngines)
	{
		test2!(BcryptECDSAEngine!(ECDSAType.p256))();
		test2!(BcryptECDSAEngine!(ECDSAType.p256k))();
		test2!(BcryptECDSAEngine!(ECDSAType.p384))();
		test2!(BcryptECDSAEngine!(ECDSAType.p521))();
	}
	
	static if (enableOpenSSLCmdEngines) if (isCommandExisting(defaultOpenSSLCommand))
	{
		test3!(OpenSSLCmdECDSAEngine!(ECDSAType.p256))();
		test3!(OpenSSLCmdECDSAEngine!(ECDSAType.p256k))();
		test3!(OpenSSLCmdECDSAEngine!(ECDSAType.p384))();
		test3!(OpenSSLCmdECDSAEngine!(ECDSAType.p521))();
	}
	
	static if (enableOpenSSLEngines)
	{
		test3!(OpenSSLECDSAEngine!(ECDSAType.p256))();
		test3!(OpenSSLECDSAEngine!(ECDSAType.p256k))();
		test3!(OpenSSLECDSAEngine!(ECDSAType.p384))();
		test3!(OpenSSLECDSAEngine!(ECDSAType.p521))();
	}
	
	static if (enableBcryptEngines)
	{
		test3!(BcryptECDSAEngine!(ECDSAType.p256))();
		test3!(BcryptECDSAEngine!(ECDSAType.p256k))();
		test3!(BcryptECDSAEngine!(ECDSAType.p384))();
		test3!(BcryptECDSAEngine!(ECDSAType.p521))();
	}
}

// RSA 4096 for OpenSSL
static if (enableOpenSSLEngines) @system unittest
{
	import std.string;
	// openssl genrsa 4096 2>/dev/null
	auto prvKeyPem = "-----BEGIN RSA PRIVATE KEY-----\r\n"
		~ "MIIJKgIBAAKCAgEA7sGFJRyFf8LuidSTHyPZZkaDUleJL7a0K2h8zQNFlH8tnLih\r\n"
		~ "0KZLYmbZW8r+N/qQQHi/bn6YaN0yf835sfvBtvMjZgvqxlGSuIatMbey8mC16NhQ\r\n"
		~ "CDYpbzq3Vtq8iITNdfo2kCWA+5Tc9xAcvnM/xQgAvaizKkSZFSdIFn53xXaFaZLG\r\n"
		~ "jOQfWC4oHMvsBZhIa3Bu6pG1nAeC4h2YLXG6MpxvlTPwtEaP/nWHXUzM6uRaXW7s\r\n"
		~ "vBnG1ktB2srdBMWMORzRXTyKsJZ4QKtVsQeSXxacDjsI96H1KEotxJFckNu03Uf4\r\n"
		~ "J9u+F4H4UWqr3m26SZ2A4qnfo3s3HFcN1oakIGWOPDguIv7b1yqzBnIBGuZZjvv6\r\n"
		~ "hYPMV7HjCaKScoDhJG2ryHdj1XibH7M18elxaD/VaE6hZIAu/l/WElL3GzAqtGWX\r\n"
		~ "XtmpqedLOZHg8Fhsl8kdHuU+j+cZ8Bmitb0+rWpKI5RI8eZkWDU1N5hDaL2SNEAy\r\n"
		~ "oPEp6I6AtHO/jSig62kaia6PJGTLGDkIdhjJ6idNXBvBLAySUyE7gJ3y6ktFljSo\r\n"
		~ "T5dfiGkNWBPF8SliVxDeFahcFoLcpc4+phZaPXcXjhojwwAFkGsCGHu6dvKJNIwa\r\n"
		~ "JpZE31RPnFsCtZj55e0LZui8QfcqVWfGJyk1WiONN0flW6dOGgW3eOsL6IsCAwEA\r\n"
		~ "AQKCAgEAvntKfIc6wumEYhZkog153q0XDFSmMJj1OUSNfQrFMmocu9JZ1xs1PXaM\r\n"
		~ "pz1WgNa4y5cKM19wvQjsxyZPtf4DWLC2Zy3OyxY9llZsSyQh8lnSB8i8YTDE8ebI\r\n"
		~ "atTsYYaCXUOY0Hv7YbwsZjhGlnNgRxPRc37qIijEcSn7y2Zuq+2ZFtdw7Or7TuDU\r\n"
		~ "Q9U1omkSLhVviFljqO4dL8Uoqej4AnToWQMtYMaDDyI5MuiY/DXfGnfrC08NYd58\r\n"
		~ "1c/PcYUiEFa7ekVY6PXDTuTi4vAFiTOCoZ/b0aU28EPuK8tFLJT8wSYwB6y7Bgo9\r\n"
		~ "UMdoA3dLjnvIXg3lTIp7N3MEqUiWG3Ac2RBvds9/Aajn9hn6YtP9cqHQTf7rfaaY\r\n"
		~ "Jtlz6ZjXbqvZtQTd02/OlvvoKtOSqEg/y0WLGC/NQVtKB8Y8KCWtAGF6pmb3uciB\r\n"
		~ "9wbOS9F9o0ipigktPtgkeDTl9/1DV8h6oApAjnPW0r7mwXvT7twb+5+2GZ+h3jST\r\n"
		~ "IfHpcP+l7fobfltog7Jie+X49VFbuXWsCys1UBDDonGjRyS4eNQKylcGibhLBXU2\r\n"
		~ "iPgF86GNZUYG+T4kZQ3xOQdcPYqaU/GUar7Tm0p4HSvL3Jga2PoV9wfEKGzxnVBs\r\n"
		~ "9o6n3x7KoB4IX7oX4o2kpXv7KmzYfZUffeor55ecmDyErBOLA6ECggEBAPvOwCqP\r\n"
		~ "TW/fRST6St87S+wgjB2pTFlX+Jmi8v7lazlTnHhknx7FjV7G+x469uk3BL07QGjF\r\n"
		~ "2EVAn2n0vZm/TVmsYdT7Jkr2t3nO7zmUeQ9VpZhq/gnRkPSjRKj0lX6rlHXvgWnI\r\n"
		~ "rANdCIuCtltxI6dgpZ4FHWd+fAhOkoR01szadxeLMB0CfoBvCw26GIua6MOXEiP/\r\n"
		~ "jIC70B8VkmpbGra0qSoGrlVXGpQ1Q9SQLVuX+o0CS9bD3cZzm9Rsg98xEJx48q32\r\n"
		~ "ykxP7C/e5hDceUxHtjozlr6NDVNdY+pEp+mh0FOlkykcSpa7ra0chXBAxA+U4yRe\r\n"
		~ "yWEJDsVCC0PgYxkCggEBAPK7JA2oMwf2JpnuC/zrNgye/rNVlPFqvirvXQxDgGMN\r\n"
		~ "65aks/uRWDODhOCAs1KS83FUBBc4Agl0EbxafF8IAYg/VBIPMV8qpPMr0dFLrfT5\r\n"
		~ "+gXILVu/XltBGCXErFs66aiZTTargyfBIwBmlVGX+5XkCus4SeHNgv7Pj43rleRG\r\n"
		~ "eIx2lTgDoPjOFNMSxeMJkMLvTiwfiO953GViePBU5Hv/xdqJf3/0rd80T9SOv8gb\r\n"
		~ "HUn+ogb0YX/pglcEh7pjVrnuXSCvZP6fntN7IT3u247ReVE/nzOMzS+JXBiUi4XB\r\n"
		~ "57+a2oXDm2tnTjHy/l4KDIIHuhQGfUM5L6x2mboh4UMCggEBAOznVVA1RmuMKWdi\r\n"
		~ "u/JNvV5IOMrnLteXtmIFNoytlzV1/m4ebL3sqtaSakvEuewsQR8vkaeBC7oL1G9B\r\n"
		~ "POhbXRCS5/AS4bIBcBj/oX4Qu9y7fXJqptrh+XjP6pbylXt5PdG/JYg6rer0Kkfn\r\n"
		~ "EF3zkdG1UdvbgBCQpWzDT4Gi0zwkBYt2/iss34tB7apafSFK+taZWQ3ZLX0oNeQo\r\n"
		~ "zXmWgQmH6ueJJZdQvcbWXhysEKBt2eG0WVmTKSG+PsuZ1G+1n6U2/UrCNw2Y2+Ml\r\n"
		~ "2Fngs5Yamc0kIBziY7kc0hXjxf4+qNspmcxBu8MYi4ukm75CkLMAJrtfGiNa/DSF\r\n"
		~ "sEeJ4nECggEACoAD8D9NbdO9Gb2NcTRvkx4xoGpcVhErBspx+PzWifJpNYwMaR6B\r\n"
		~ "dUEEN335w+GtfEKJJsP6epQ1zDMR3D6Jam5q4ZkcpqQ+nHJR0j722HkT0ro1FBn0\r\n"
		~ "J/hp5gBbAFtNDkkLaQkEVGzrabIGVZBAhtxliIVX1NfCCenKqPX+9vABePoMPG8T\r\n"
		~ "wI+RoQvX2ZlpVLVraUc38jwQR6Z52tOhSqfm1CxMgql/9/7YUTaXnz1lB/Vm5uwd\r\n"
		~ "Z54fUEpW4L45WzOvfaF4ufcHtNhHuNkjUEtJdzVMWruFiL/lZv7OBkw8DTLSrySm\r\n"
		~ "DYBbhpefX0wJ/Hn/F6ysMINBx7Edt0qN5wKCAQEApvMWbJnjztZeN4mi5B+d4gSh\r\n"
		~ "HMcXZOtsjqS0IRocoXCNjzYJZjlR0kLdiV6uQSOWVXutcol4ZGyOeWnN3eTkD2xa\r\n"
		~ "1USPCgnlUIGEVSU5cBKdpDDY1nIdpt2ropXVGnN9wYq+k5ta+tQfc6G4DmlzQ6H1\r\n"
		~ "CNDTPEtvaZCfSpK1tWFwo3HrFmKFSEXl/5fkKOiv9h40uqTDdHkwCfi+s2YWxFp2\r\n"
		~ "BZEbOGC2MZIEpvbBi0CF6KZO752Zh3SPuj4puhrchOYSR5RO52IliPe4T1CTydES\r\n"
		~ "djc2isb0cYRPjWsoSEwnemqYeJM/jURB1UUPqKWMbuJhl3qHW3lxuzIugKHrWg==\r\n"
		~ "-----END RSA PRIVATE KEY-----\r\n";
	auto prvKeyDer = cast(immutable(ubyte)[])(x"3082092A" // SEQUENCE 2346 bytes
		~ x"0201"~x"00"     // INTEGER: version 0
		~ x"02820201"       // INTEGER: modulus (513 bytes = 0x00 + 512bytes)
			~ x"00EEC185251C857FC2EE89D4931F23D96646835257892FB6B42B687CCD0345947F"
			~ x"2D9CB8A1D0A64B6266D95BCAFE37FA904078BF6E7E9868DD327FCDF9B1FBC1B6"
			~ x"F323660BEAC65192B886AD31B7B2F260B5E8D8500836296F3AB756DABC8884CD"
			~ x"75FA36902580FB94DCF7101CBE733FC50800BDA8B32A4499152748167E77C576"
			~ x"856992C68CE41F582E281CCBEC0598486B706EEA91B59C0782E21D982D71BA32"
			~ x"9C6F9533F0B4468FFE75875D4CCCEAE45A5D6EECBC19C6D64B41DACADD04C58C"
			~ x"391CD15D3C8AB0967840AB55B107925F169C0E3B08F7A1F5284A2DC4915C90DB"
			~ x"B4DD47F827DBBE1781F8516AABDE6DBA499D80E2A9DFA37B371C570DD686A420"
			~ x"658E3C382E22FEDBD72AB30672011AE6598EFBFA8583CC57B1E309A2927280E1"
			~ x"246DABC87763D5789B1FB335F1E971683FD5684EA164802EFE5FD61252F71B30"
			~ x"2AB465975ED9A9A9E74B3991E0F0586C97C91D1EE53E8FE719F019A2B5BD3EAD"
			~ x"6A4A239448F1E66458353537984368BD92344032A0F129E88E80B473BF8D28A0"
			~ x"EB691A89AE8F2464CB1839087618C9EA274D5C1BC12C0C9253213B809DF2EA4B"
			~ x"459634A84F975F88690D5813C5F129625710DE15A85C1682DCA5CE3EA6165A3D"
			~ x"77178E1A23C30005906B02187BBA76F289348C1A269644DF544F9C5B02B598F9"
			~ x"E5ED0B66E8BC41F72A5567C62729355A238D3747E55BA74E1A05B778EB0BE88B"
		~ x"0203"~x"010001" // INTEGER: publicExponent (3 bytes)
		~ x"02820201"       // INTEGER: privateExponent (513 bytes = 0x00 + 512 bytes)
			~ x"00BE7B4A7C873AC2E984621664A20D79DEAD170C54A63098F539448D7D0AC5326A"
			~ x"1CBBD259D71B353D768CA73D5680D6B8CB970A335F70BD08ECC7264FB5FE0358"
			~ x"B0B6672DCECB163D96566C4B2421F259D207C8BC6130C4F1E6C86AD4EC618682"
			~ x"5D4398D07BFB61BC2C6638469673604713D1737EEA2228C47129FBCB666EABED"
			~ x"9916D770ECEAFB4EE0D443D535A269122E156F885963A8EE1D2FC528A9E8F802"
			~ x"74E859032D60C6830F223932E898FC35DF1A77EB0B4F0D61DE7CD5CFCF718522"
			~ x"1056BB7A4558E8F5C34EE4E2E2F005893382A19FDBD1A536F043EE2BCB452C94"
			~ x"FCC1263007ACBB060A3D50C76803774B8E7BC85E0DE54C8A7B377304A948961B"
			~ x"701CD9106F76CF7F01A8E7F619FA62D3FD72A1D04DFEEB7DA69826D973E998D7"
			~ x"6EABD9B504DDD36FCE96FBE82AD392A8483FCB458B182FCD415B4A07C63C2825"
			~ x"AD00617AA666F7B9C881F706CE4BD17DA348A98A092D3ED8247834E5F7FD4357"
			~ x"C87AA00A408E73D6D2BEE6C17BD3EEDC1BFB9FB6199FA1DE349321F1E970FFA5"
			~ x"EDFA1B7E5B6883B2627BE5F8F5515BB975AC0B2B355010C3A271A34724B878D4"
			~ x"0ACA570689B84B05753688F805F3A18D654606F93E24650DF139075C3D8A9A53"
			~ x"F1946ABED39B4A781D2BCBDC981AD8FA15F707C4286CF19D506CF68EA7DF1ECA"
			~ x"A01E085FBA17E28DA4A57BFB2A6CD87D951F7DEA2BE7979C983C84AC138B03A1"
		~ x"02820101"       // INTEGER: prime1 (257 bytes = 0x00 + 256 bytes)
			~ x"00FBCEC02A8F4D6FDF4524FA4ADF3B4BEC208C1DA94C5957F899A2F2FEE56B3953"
			~ x"9C78649F1EC58D5EC6FB1E3AF6E93704BD3B4068C5D845409F69F4BD99BF4D59"
			~ x"AC61D4FB264AF6B779CEEF3994790F55A5986AFE09D190F4A344A8F4957EAB94"
			~ x"75EF8169C8AC035D088B82B65B7123A760A59E051D677E7C084E928474D6CCDA"
			~ x"77178B301D027E806F0B0DBA188B9AE8C3971223FF8C80BBD01F15926A5B1AB6"
			~ x"B4A92A06AE55571A943543D4902D5B97FA8D024BD6C3DDC6739BD46C83DF3110"
			~ x"9C78F2ADF6CA4C4FEC2FDEE610DC794C47B63A3396BE8D0D535D63EA44A7E9A1"
			~ x"D053A593291C4A96BBADAD1C857040C40F94E3245EC961090EC5420B43E06319"
		~ x"02820101"       // INTEGER: prime2 (257 bytes = 0x00 + 256 bytes)
			~ x"00F2BB240DA83307F62699EE0BFCEB360C9EFEB35594F16ABE2AEF5D0C4380630D"
			~ x"EB96A4B3FB9158338384E080B35292F3715404173802097411BC5A7C5F080188"
			~ x"3F54120F315F2AA4F32BD1D14BADF4F9FA05C82D5BBF5E5B411825C4AC5B3AE9"
			~ x"A8994D36AB8327C1230066955197FB95E40AEB3849E1CD82FECF8F8DEB95E446"
			~ x"788C76953803A0F8CE14D312C5E30990C2EF4E2C1F88EF79DC656278F054E47B"
			~ x"FFC5DA897F7FF4ADDF344FD48EBFC81B1D49FEA206F4617FE982570487BA6356"
			~ x"B9EE5D20AF64FE9F9ED37B213DEEDB8ED179513F9F338CCD2F895C18948B85C1"
			~ x"E7BF9ADA85C39B6B674E31F2FE5E0A0C8207BA14067D43392FAC7699BA21E143"
		~ x"02820101"       // INTEGER: exponent1 (257 bytes = 0x00 + 256 bytes)
			~ x"00ECE7555035466B8C296762BBF24DBD5E4838CAE72ED797B66205368CAD973575"
			~ x"FE6E1E6CBDECAAD6926A4BC4B9EC2C411F2F91A7810BBA0BD46F413CE85B5D10"
			~ x"92E7F012E1B2017018FFA17E10BBDCBB7D726AA6DAE1F978CFEA96F2957B793D"
			~ x"D1BF25883AADEAF42A47E7105DF391D1B551DBDB801090A56CC34F81A2D33C24"
			~ x"058B76FE2B2CDF8B41EDAA5A7D214AFAD699590DD92D7D2835E428CD79968109"
			~ x"87EAE789259750BDC6D65E1CAC10A06DD9E1B45959932921BE3ECB99D46FB59F"
			~ x"A536FD4AC2370D98DBE325D859E0B3961A99CD24201CE263B91CD215E3C5FE3E"
			~ x"A8DB2999CC41BBC3188B8BA49BBE4290B30026BB5F1A235AFC3485B04789E271"
		~ x"02820100"       // INTEGER: exponent2 (256 bytes)
			~ x"0A8003F03F4D6DD3BD19BD8D71346F931E31A06A5C56112B06CA71F8FCD689F2"
			~ x"69358C0C691E81754104377DF9C3E1AD7C428926C3FA7A9435CC3311DC3E896A"
			~ x"6E6AE1991CA6A43E9C7251D23EF6D87913D2BA351419F427F869E6005B005B4D"
			~ x"0E490B690904546CEB69B20655904086DC65888557D4D7C209E9CAA8F5FEF6F0"
			~ x"0178FA0C3C6F13C08F91A10BD7D9996954B56B694737F23C1047A679DAD3A14A"
			~ x"A7E6D42C4C82A97FF7FED85136979F3D6507F566E6EC1D679E1F504A56E0BE39"
			~ x"5B33AF7DA178B9F707B4D847B8D923504B4977354C5ABB8588BFE566FECE064C"
			~ x"3C0D32D2AF24A60D805B86979F5F4C09FC79FF17ACAC308341C7B11DB74A8DE7"
		~ x"02820101"       // INTEGER: coefficient (257 bytes = 0x00 + 256 bytes)
			~ x"00A6F3166C99E3CED65E3789A2E41F9DE204A11CC71764EB6C8EA4B4211A1CA170"
			~ x"8D8F3609663951D242DD895EAE412396557BAD728978646C8E7969CDDDE4E40F"
			~ x"6C5AD5448F0A09E550818455253970129DA430D8D6721DA6DDABA295D51A737D"
			~ x"C18ABE939B5AFAD41F73A1B80E697343A1F508D0D33C4B6F69909F4A92B5B561"
			~ x"70A371EB1662854845E5FF97E428E8AFF61E34BAA4C374793009F8BEB36616C4"
			~ x"5A7605911B3860B6319204A6F6C18B4085E8A64EEF9D9987748FBA3E29BA1ADC"
			~ x"84E61247944EE7622588F7B84F5093C9D1127637368AC6F471844F8D6B28484C"
			~ x"277A6A9878933F8D4441D5450FA8A58C6EE261977A875B7971BB322E80A1EB5A"
		);
	auto prvKeyBin = cast(immutable(ubyte)[2308])(x""
		// INTEGER: modulus (512 bytes)
		~ x"EEC185251C857FC2EE89D4931F23D96646835257892FB6B42B687CCD0345947F"
		~ x"2D9CB8A1D0A64B6266D95BCAFE37FA904078BF6E7E9868DD327FCDF9B1FBC1B6"
		~ x"F323660BEAC65192B886AD31B7B2F260B5E8D8500836296F3AB756DABC8884CD"
		~ x"75FA36902580FB94DCF7101CBE733FC50800BDA8B32A4499152748167E77C576"
		~ x"856992C68CE41F582E281CCBEC0598486B706EEA91B59C0782E21D982D71BA32"
		~ x"9C6F9533F0B4468FFE75875D4CCCEAE45A5D6EECBC19C6D64B41DACADD04C58C"
		~ x"391CD15D3C8AB0967840AB55B107925F169C0E3B08F7A1F5284A2DC4915C90DB"
		~ x"B4DD47F827DBBE1781F8516AABDE6DBA499D80E2A9DFA37B371C570DD686A420"
		~ x"658E3C382E22FEDBD72AB30672011AE6598EFBFA8583CC57B1E309A2927280E1"
		~ x"246DABC87763D5789B1FB335F1E971683FD5684EA164802EFE5FD61252F71B30"
		~ x"2AB465975ED9A9A9E74B3991E0F0586C97C91D1EE53E8FE719F019A2B5BD3EAD"
		~ x"6A4A239448F1E66458353537984368BD92344032A0F129E88E80B473BF8D28A0"
		~ x"EB691A89AE8F2464CB1839087618C9EA274D5C1BC12C0C9253213B809DF2EA4B"
		~ x"459634A84F975F88690D5813C5F129625710DE15A85C1682DCA5CE3EA6165A3D"
		~ x"77178E1A23C30005906B02187BBA76F289348C1A269644DF544F9C5B02B598F9"
		~ x"E5ED0B66E8BC41F72A5567C62729355A238D3747E55BA74E1A05B778EB0BE88B"
		// INTEGER: publicExponent (4 bytes)
		~ x"00010001"
		// INTEGER: privateExponent (512 bytes)
		~ x"BE7B4A7C873AC2E984621664A20D79DEAD170C54A63098F539448D7D0AC5326A"
		~ x"1CBBD259D71B353D768CA73D5680D6B8CB970A335F70BD08ECC7264FB5FE0358"
		~ x"B0B6672DCECB163D96566C4B2421F259D207C8BC6130C4F1E6C86AD4EC618682"
		~ x"5D4398D07BFB61BC2C6638469673604713D1737EEA2228C47129FBCB666EABED"
		~ x"9916D770ECEAFB4EE0D443D535A269122E156F885963A8EE1D2FC528A9E8F802"
		~ x"74E859032D60C6830F223932E898FC35DF1A77EB0B4F0D61DE7CD5CFCF718522"
		~ x"1056BB7A4558E8F5C34EE4E2E2F005893382A19FDBD1A536F043EE2BCB452C94"
		~ x"FCC1263007ACBB060A3D50C76803774B8E7BC85E0DE54C8A7B377304A948961B"
		~ x"701CD9106F76CF7F01A8E7F619FA62D3FD72A1D04DFEEB7DA69826D973E998D7"
		~ x"6EABD9B504DDD36FCE96FBE82AD392A8483FCB458B182FCD415B4A07C63C2825"
		~ x"AD00617AA666F7B9C881F706CE4BD17DA348A98A092D3ED8247834E5F7FD4357"
		~ x"C87AA00A408E73D6D2BEE6C17BD3EEDC1BFB9FB6199FA1DE349321F1E970FFA5"
		~ x"EDFA1B7E5B6883B2627BE5F8F5515BB975AC0B2B355010C3A271A34724B878D4"
		~ x"0ACA570689B84B05753688F805F3A18D654606F93E24650DF139075C3D8A9A53"
		~ x"F1946ABED39B4A781D2BCBDC981AD8FA15F707C4286CF19D506CF68EA7DF1ECA"
		~ x"A01E085FBA17E28DA4A57BFB2A6CD87D951F7DEA2BE7979C983C84AC138B03A1"
		// INTEGER: prime1 (256 bytes)
		~ x"FBCEC02A8F4D6FDF4524FA4ADF3B4BEC208C1DA94C5957F899A2F2FEE56B3953"
		~ x"9C78649F1EC58D5EC6FB1E3AF6E93704BD3B4068C5D845409F69F4BD99BF4D59"
		~ x"AC61D4FB264AF6B779CEEF3994790F55A5986AFE09D190F4A344A8F4957EAB94"
		~ x"75EF8169C8AC035D088B82B65B7123A760A59E051D677E7C084E928474D6CCDA"
		~ x"77178B301D027E806F0B0DBA188B9AE8C3971223FF8C80BBD01F15926A5B1AB6"
		~ x"B4A92A06AE55571A943543D4902D5B97FA8D024BD6C3DDC6739BD46C83DF3110"
		~ x"9C78F2ADF6CA4C4FEC2FDEE610DC794C47B63A3396BE8D0D535D63EA44A7E9A1"
		~ x"D053A593291C4A96BBADAD1C857040C40F94E3245EC961090EC5420B43E06319"
		// INTEGER: prime2 (256 bytes)
		~ x"F2BB240DA83307F62699EE0BFCEB360C9EFEB35594F16ABE2AEF5D0C4380630D"
		~ x"EB96A4B3FB9158338384E080B35292F3715404173802097411BC5A7C5F080188"
		~ x"3F54120F315F2AA4F32BD1D14BADF4F9FA05C82D5BBF5E5B411825C4AC5B3AE9"
		~ x"A8994D36AB8327C1230066955197FB95E40AEB3849E1CD82FECF8F8DEB95E446"
		~ x"788C76953803A0F8CE14D312C5E30990C2EF4E2C1F88EF79DC656278F054E47B"
		~ x"FFC5DA897F7FF4ADDF344FD48EBFC81B1D49FEA206F4617FE982570487BA6356"
		~ x"B9EE5D20AF64FE9F9ED37B213DEEDB8ED179513F9F338CCD2F895C18948B85C1"
		~ x"E7BF9ADA85C39B6B674E31F2FE5E0A0C8207BA14067D43392FAC7699BA21E143"
		// INTEGER: exponent1 (256 bytes)
		~ x"ECE7555035466B8C296762BBF24DBD5E4838CAE72ED797B66205368CAD973575"
		~ x"FE6E1E6CBDECAAD6926A4BC4B9EC2C411F2F91A7810BBA0BD46F413CE85B5D10"
		~ x"92E7F012E1B2017018FFA17E10BBDCBB7D726AA6DAE1F978CFEA96F2957B793D"
		~ x"D1BF25883AADEAF42A47E7105DF391D1B551DBDB801090A56CC34F81A2D33C24"
		~ x"058B76FE2B2CDF8B41EDAA5A7D214AFAD699590DD92D7D2835E428CD79968109"
		~ x"87EAE789259750BDC6D65E1CAC10A06DD9E1B45959932921BE3ECB99D46FB59F"
		~ x"A536FD4AC2370D98DBE325D859E0B3961A99CD24201CE263B91CD215E3C5FE3E"
		~ x"A8DB2999CC41BBC3188B8BA49BBE4290B30026BB5F1A235AFC3485B04789E271"
		// INTEGER: exponent2 (256 bytes)
		~ x"0A8003F03F4D6DD3BD19BD8D71346F931E31A06A5C56112B06CA71F8FCD689F2"
		~ x"69358C0C691E81754104377DF9C3E1AD7C428926C3FA7A9435CC3311DC3E896A"
		~ x"6E6AE1991CA6A43E9C7251D23EF6D87913D2BA351419F427F869E6005B005B4D"
		~ x"0E490B690904546CEB69B20655904086DC65888557D4D7C209E9CAA8F5FEF6F0"
		~ x"0178FA0C3C6F13C08F91A10BD7D9996954B56B694737F23C1047A679DAD3A14A"
		~ x"A7E6D42C4C82A97FF7FED85136979F3D6507F566E6EC1D679E1F504A56E0BE39"
		~ x"5B33AF7DA178B9F707B4D847B8D923504B4977354C5ABB8588BFE566FECE064C"
		~ x"3C0D32D2AF24A60D805B86979F5F4C09FC79FF17ACAC308341C7B11DB74A8DE7"
		// INTEGER: coefficient (256 bytes)
		~ x"A6F3166C99E3CED65E3789A2E41F9DE204A11CC71764EB6C8EA4B4211A1CA170"
		~ x"8D8F3609663951D242DD895EAE412396557BAD728978646C8E7969CDDDE4E40F"
		~ x"6C5AD5448F0A09E550818455253970129DA430D8D6721DA6DDABA295D51A737D"
		~ x"C18ABE939B5AFAD41F73A1B80E697343A1F508D0D33C4B6F69909F4A92B5B561"
		~ x"70A371EB1662854845E5FF97E428E8AFF61E34BAA4C374793009F8BEB36616C4"
		~ x"5A7605911B3860B6319204A6F6C18B4085E8A64EEF9D9987748FBA3E29BA1ADC"
		~ x"84E61247944EE7622588F7B84F5093C9D1127637368AC6F471844F8D6B28484C"
		~ x"277A6A9878933F8D4441D5450FA8A58C6EE261977A875B7971BB322E80A1EB5A"
		);
	// openssl rsa -in private_key_rsa4096.pem -pubout -out -
	auto pubKeyPem = "-----BEGIN PUBLIC KEY-----\r\n"
		~ "MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA7sGFJRyFf8LuidSTHyPZ\r\n"
		~ "ZkaDUleJL7a0K2h8zQNFlH8tnLih0KZLYmbZW8r+N/qQQHi/bn6YaN0yf835sfvB\r\n"
		~ "tvMjZgvqxlGSuIatMbey8mC16NhQCDYpbzq3Vtq8iITNdfo2kCWA+5Tc9xAcvnM/\r\n"
		~ "xQgAvaizKkSZFSdIFn53xXaFaZLGjOQfWC4oHMvsBZhIa3Bu6pG1nAeC4h2YLXG6\r\n"
		~ "MpxvlTPwtEaP/nWHXUzM6uRaXW7svBnG1ktB2srdBMWMORzRXTyKsJZ4QKtVsQeS\r\n"
		~ "XxacDjsI96H1KEotxJFckNu03Uf4J9u+F4H4UWqr3m26SZ2A4qnfo3s3HFcN1oak\r\n"
		~ "IGWOPDguIv7b1yqzBnIBGuZZjvv6hYPMV7HjCaKScoDhJG2ryHdj1XibH7M18elx\r\n"
		~ "aD/VaE6hZIAu/l/WElL3GzAqtGWXXtmpqedLOZHg8Fhsl8kdHuU+j+cZ8Bmitb0+\r\n"
		~ "rWpKI5RI8eZkWDU1N5hDaL2SNEAyoPEp6I6AtHO/jSig62kaia6PJGTLGDkIdhjJ\r\n"
		~ "6idNXBvBLAySUyE7gJ3y6ktFljSoT5dfiGkNWBPF8SliVxDeFahcFoLcpc4+phZa\r\n"
		~ "PXcXjhojwwAFkGsCGHu6dvKJNIwaJpZE31RPnFsCtZj55e0LZui8QfcqVWfGJyk1\r\n"
		~ "WiONN0flW6dOGgW3eOsL6IsCAwEAAQ==\r\n"
		~ "-----END PUBLIC KEY-----\r\n";
	auto pubKeyDer = cast(immutable(ubyte)[])(x"30820222"        // SEQUENCE (546 bytes)
		~ x"300d"~x"06092a864886f70d0101010500" // SEQUENCE (13 bytes) / OID rsaEncryption
		~ x"0382020f00"                 // BIT STRING (527 bytes / 0bits)
			~ x"3082020a"                   // SEQUENCE (522)
				~ x"02820201"                   // INTEGER: modulus (513 bytes)
					~ x"00eec185251c857fc2ee89d4931f23d96646835257892fb6b42b687ccd0345947f"
					~ x"2d9cb8a1d0a64b6266d95bcafe37fa904078bf6e7e9868dd327fcdf9b1fbc1b6"
					~ x"f323660beac65192b886ad31b7b2f260b5e8d8500836296f3ab756dabc8884cd"
					~ x"75fa36902580fb94dcf7101cbe733fc50800bda8b32a4499152748167e77c576"
					~ x"856992c68ce41f582e281ccbec0598486b706eea91b59c0782e21d982d71ba32"
					~ x"9c6f9533f0b4468ffe75875d4ccceae45a5d6eecbc19c6d64b41dacadd04c58c"
					~ x"391cd15d3c8ab0967840ab55b107925f169c0e3b08f7a1f5284a2dc4915c90db"
					~ x"b4dd47f827dbbe1781f8516aabde6dba499d80e2a9dfa37b371c570dd686a420"
					~ x"658e3c382e22fedbd72ab30672011ae6598efbfa8583cc57b1e309a2927280e1"
					~ x"246dabc87763d5789b1fb335f1e971683fd5684ea164802efe5fd61252f71b30"
					~ x"2ab465975ed9a9a9e74b3991e0f0586c97c91d1ee53e8fe719f019a2b5bd3ead"
					~ x"6a4a239448f1e66458353537984368bd92344032a0f129e88e80b473bf8d28a0"
					~ x"eb691a89ae8f2464cb1839087618c9ea274d5c1bc12c0c9253213b809df2ea4b"
					~ x"459634a84f975f88690d5813c5f129625710de15a85c1682dca5ce3ea6165a3d"
					~ x"77178e1a23c30005906b02187bba76f289348c1a269644df544f9c5b02b598f9"
					~ x"e5ed0b66e8bc41f72a5567c62729355a238d3747e55ba74e1a05b778eb0be88b"
				~ x"0203"~x"010001"             // INTEGER: publicExponent (3 bytes)
		);
	auto pubKeyBin = cast(immutable(ubyte)[516])(x""
		// INTEGER: modulus (512 bytes)
		~ x"eec185251c857fc2ee89d4931f23d96646835257892fb6b42b687ccd0345947f"
		~ x"2d9cb8a1d0a64b6266d95bcafe37fa904078bf6e7e9868dd327fcdf9b1fbc1b6"
		~ x"f323660beac65192b886ad31b7b2f260b5e8d8500836296f3ab756dabc8884cd"
		~ x"75fa36902580fb94dcf7101cbe733fc50800bda8b32a4499152748167e77c576"
		~ x"856992c68ce41f582e281ccbec0598486b706eea91b59c0782e21d982d71ba32"
		~ x"9c6f9533f0b4468ffe75875d4ccceae45a5d6eecbc19c6d64b41dacadd04c58c"
		~ x"391cd15d3c8ab0967840ab55b107925f169c0e3b08f7a1f5284a2dc4915c90db"
		~ x"b4dd47f827dbbe1781f8516aabde6dba499d80e2a9dfa37b371c570dd686a420"
		~ x"658e3c382e22fedbd72ab30672011ae6598efbfa8583cc57b1e309a2927280e1"
		~ x"246dabc87763d5789b1fb335f1e971683fd5684ea164802efe5fd61252f71b30"
		~ x"2ab465975ed9a9a9e74b3991e0f0586c97c91d1ee53e8fe719f019a2b5bd3ead"
		~ x"6a4a239448f1e66458353537984368bd92344032a0f129e88e80b473bf8d28a0"
		~ x"eb691a89ae8f2464cb1839087618c9ea274d5c1bc12c0c9253213b809df2ea4b"
		~ x"459634a84f975f88690d5813c5f129625710de15a85c1682dca5ce3ea6165a3d"
		~ x"77178e1a23c30005906b02187bba76f289348c1a269644df544f9c5b02b598f9"
		~ x"e5ed0b66e8bc41f72a5567c62729355a238d3747e55ba74e1a05b778eb0be88b"
		// INTEGER: publicExponent (4 bytes)
		~ x"00010001"
		);
	// openssl pkeyutl -sign -inkey private_key_rsa4096.pem -in test.txt -out -
	auto signatureExample1 = cast(immutable(ubyte)[])(x""
		~ x"8c4d1661b50749b7e54554204697d0dd99b54fe37cbbc25a012065723fb126f4"
		~ x"a94a81c5a7bf4f8e3bd63224b036857e2e1b0ffb74581b054037ce48430356fb"
		~ x"c7018314f845570cddad47040183ec8ce88a52a1b8ed3c430c7b37bfb547eb86"
		~ x"2fb52c802e7e1b4e643a55655d5ecc3f8a4dd6cbf6fde01cf1e30106d5c4942a"
		~ x"3d29201d96b96da49f7bb2b3d741fb80ba6f3dbd20304f7c76778951c1a5a08f"
		~ x"0ed1a74988664987c4f5e9b63a4e5927dbb57a09c45a0380c685aa26a25cbb1d"
		~ x"451d54d6842098eab816f2f84845d454d64218cda4a8d09b17394958cc0d0834"
		~ x"a1273af4a7ef07bb387ada53515a2c69735ec8bdf731032deb34d97490570e9f"
		~ x"7a72967fd456efd69fafc93f0d087a7be9cd62a5756023b14e0edc6aa3f9eabc"
		~ x"6e52a8a41a6b6705ecdb5ab26b1c2866b9c1a464f0c85fd8230fe9ad4bd4b7b8"
		~ x"963deda74470f0b2d7ee1c859264a5b727bf0df9374ccde04517c3905e0f6eee"
		~ x"eddd1e500ed373b2a163b4283e4d74b48743c51e70445771e793233493df7070"
		~ x"794cda111a9102acfe4aacd4dea31a8d742e4be5e21ca9809089f55f3172fffb"
		~ x"89f6356943565db8da1abded93381495fca6ddcb584fc3cca3dbd683f2e8dbbb"
		~ x"bf2cec673f9704f8d6ef53faf4565c2137b646b58918ce03894d187de56d30ee"
		~ x"68c07e3e0e9177f804595726e61d3f44d8993a192c48470d6003e894edebd500");
	// openssl dgst -sha256 -binary test.txt | openssl pkeyutl -sign -inkey private_key_rsa4096.pem -out sign_rsa.bin
	// openssl dgst -sha256 -binary test.txt | openssl pkeyutl -verify -pubin -inkey public_key_rsa4096.pem -sigfile sign_rsa.bin
	auto signaturePhSHA256Example1 = cast(immutable(ubyte)[])(x""
		~ x"BBBB37C625DD3D17BA76E657C82D8781EA5CF0C877A001FEC9C35E37B47CD82F"
		~ x"45F7AA876705FB0BCF14B5850EDC7A832AD824F1E4170F04680F2AF4691FCF41"
		~ x"FABCB9C01EBBB7DE038F203EF7E433EF01454054798262DC1B0FC04C97DE6DEE"
		~ x"E804E0A598F76FF44936F1304D5DA41D9BBB3FD1FE2E74FF841A17280476C170"
		~ x"260D76F5245D101E453BAAEA115053F2F352889067F07A8A0496C16A284E3E4D"
		~ x"1B0FC6BCF7AA88B0722D122B256EF5C95FB63EB9972134141E626A9B53F8ACC3"
		~ x"1C73DD2B1CFE358ACC0EA64C6070C8005B1B30B54185380F1D94C7EC97550DD4"
		~ x"992B52B529FF58374008F8D6F8DB7C31B0A49227EC7BDA8E78384C6346692FEA"
		~ x"A7AFE2DCE6F1EFCE20C891A38F90CC9E7C2DC0CDD18D53380101E8B2DD645E0D"
		~ x"5A4D786F7FE84AA358B3AA307258941B10F5C6A2D0E5844FE19153B5B0FAB1CD"
		~ x"8B327F3F2502D8065611F35D4CF42B2829A142B0FD21AE9F89F892537D46050C"
		~ x"D4767614FB6D4361DB71AD6597650DC806FF92BB0EA2CB6C2AA698D4E5F63D2C"
		~ x"2CF58D87494D18AC537F3152040C2526A02BFB22D67092E5F3701D8AB7C52A85"
		~ x"2A6E25D323C1FB736C57605619EF2E307F113FECFBF2741ED7C89E23DA6C7B16"
		~ x"AF64B649D9C17D6F8E2C08904E6F7353020E0F141BE8F77B59229FCA876B901B"
		~ x"71DE27C2A95C5473C18AC7BA27802A38EE129F4F7DC9D55D8095D1E8CC2CCD65");
	// openssl dgst -sha256 -sign private_key_rsa4096.pem -out - test.txt
	// openssl dgst -sha256 -verify public_key_rsa4096.pem -signature - test.txt
	auto signaturePhSHA256Example2 = cast(immutable(ubyte)[])(x""
		~ x"b3d5263a36ad17931b18a791011f604873d2e03a94414d978b0dda9f56ce1c5b"
		~ x"01a209aa783544d0ef586f64ce0afbffd05ff987ebc3fcda706a90b43a54039b"
		~ x"14a62f578dd9f7872a4479dbcc1d596033bbf27df54a2e2367f3d86fdd5b5ad5"
		~ x"421ffadfd87dbe2de9c57f1d96e80b559cc0e4c936499d1697677449be619277"
		~ x"d4018323dc1119d5283ad504cb498d39951fc9ae5a030eb99caa0ad566164c7f"
		~ x"dc0a40e0cfe01104eb66df5c2afcea4c01c6e3d5eaf5655bc6ba597763c389dc"
		~ x"55b7a9640e2ac3abc0a2500b54785856bc16d964d88aeb9da92363840bbaadb7"
		~ x"86ae60de9836697d4d07180622ef5345cb22919c6e0d2905e6aaea466c6ef185"
		~ x"19499442e1fd6178f5199b53c2fba3334867ff7af753e2256918143483150d60"
		~ x"0491a6172f99282137e589ea38f0e35a93bcf66d6db95edd588769067d95da11"
		~ x"dbd9d0da46a2cc68e54addf29a10ca5ce8b5ef40626769307a1686f069c03163"
		~ x"0732f448c08421acb7fb20b779ad1e57668541193b6f9abae1e9ba1d0a86ab66"
		~ x"8d4d0cd949cc59a6f8263d65b01a836be51989afd5118de20d458be31633194d"
		~ x"500b8117b9f2fd7f82bacffc8a821906b2f4b9a6f06212fb10fde3c15176a58e"
		~ x"d010d927dbe41336f965b7e4f5a82d0f11908834d0c3d95c95648a2e5a80a894"
		~ x"99beb6009620a34d582531ba88a9f003d020d8ebecf80cb723134e94032a5101");
	enum message = "Hello, World!";
	
	alias Engine = OpenSSLRSA4096Engine;
	// 自分で生成して各種検証
	auto prvKey = Engine.PrivateKey.createKey();
	auto pubKey = Engine.PublicKey.createKey(prvKey);
	auto signer = Signer!Engine(prvKey.toPEM);
	signer.update(message.representation);
	auto signature = signer.sign();
	auto verifier = Verifier!Engine(pubKey.toPEM);
	verifier.update(message.representation);
	assert(verifier.verify(signature));
	auto encrypter = Encrypter!Engine(pubKey.toPEM);
	auto encrypted = encrypter.encrypt(message.representation);
	auto decrypter = Decrypter!Engine(prvKey.toPEM);
	auto decrypted = decrypter.decrypt(encrypted);
	assert(decrypted == message.representation);
	
	// 事前準備したデータでの検証
	auto prvKey1 = Engine.PrivateKey.fromPEM(prvKeyPem);
	assert(prvKey1.toPEM().splitLines == prvKeyPem.splitLines);
	assert(prvKey1.toDER() == prvKeyDer);
	assert(prvKey1.toBinary() == prvKeyBin);
	auto prvKey2 = Engine.PrivateKey.fromDER(prvKeyDer);
	assert(prvKey2.toPEM().splitLines == prvKeyPem.splitLines);
	assert(prvKey2.toDER() == prvKeyDer);
	assert(prvKey2.toBinary() == prvKeyBin);
	auto prvKey3 = Engine.PrivateKey.fromBinary(prvKeyBin);
	assert(prvKey3.toPEM().splitLines == prvKeyPem.splitLines);
	assert(prvKey3.toDER() == prvKeyDer);
	assert(prvKey3.toBinary() == prvKeyBin);
	
	auto pubKey1 = Engine.PublicKey.fromPEM(pubKeyPem);
	assert(pubKey1.toPEM().splitLines == pubKeyPem.splitLines);
	assert(pubKey1.toDER() == pubKeyDer);
	assert(pubKey1.toBinary() == pubKeyBin);
	auto pubKey2 = Engine.PublicKey.fromDER(pubKeyDer);
	assert(pubKey2.toPEM().splitLines == pubKeyPem.splitLines);
	assert(pubKey2.toDER() == pubKeyDer);
	assert(pubKey2.toBinary() == pubKeyBin);
	auto pubKey3 = Engine.PublicKey.fromBinary(pubKeyBin);
	assert(pubKey3.toPEM().splitLines == pubKeyPem.splitLines);
	assert(pubKey3.toDER() == pubKeyDer);
	assert(pubKey3.toBinary() == pubKeyBin);
	auto pubKey4 = Engine.PublicKey.createKey(prvKey1);
	assert(pubKey4.toPEM().splitLines == pubKeyPem.splitLines);
	assert(pubKey4.toDER() == pubKeyDer);
	assert(pubKey4.toBinary() == pubKeyBin);
	
	// 署名
	auto signer1 = Signer!Engine(prvKey1.toBinary);
	signer1.update(message.representation);
	auto signature1 = signer1.sign();
	assert(signature1[] == signatureExample1[]);
	
	// 検証
	auto verifier1 = Verifier!Engine(pubKey1.toBinary);
	verifier1.update(message.representation);
	assert(verifier1.verify(signature1));
	assert(verifier1.verify(signatureExample1));
	
	// 署名(プリハッシュ)
	auto signer2 = Signer!(Engine, SHA256)(prvKey1.toBinary);
	signer2.update(message.representation);
	auto signature2 = signer2.sign();
	assert(signature2[] == signaturePhSHA256Example1[]);
	
	// 検証(プリハッシュ)
	auto verifier2 = Verifier!(Engine, SHA256)(pubKey1.toBinary);
	verifier2.update(message.representation);
	assert(verifier2.verify(signature2));
	assert(verifier2.verify(signaturePhSHA256Example1));
	
	// 暗号化
	auto encrypter1 = Encrypter!Engine(pubKey1.toPEM);
	auto encrypted1 = encrypter.encrypt(message.representation);
	
	// 復号
	auto decrypter1 = Decrypter!Engine(prvKey1.toPEM);
	auto decrypted1 = decrypter.decrypt(encrypted1);
	assert(decrypted1 == message.representation);
}
// RSA 4096 for OpenSSL
static if (enableBcryptEngines) @system unittest
{
	import std, std.file;
	import std.string;
	// openssl genrsa 4096 2>/dev/null
	auto prvKeyPem = "-----BEGIN RSA PRIVATE KEY-----\r\n"
		~ "MIIJKgIBAAKCAgEA7sGFJRyFf8LuidSTHyPZZkaDUleJL7a0K2h8zQNFlH8tnLih\r\n"
		~ "0KZLYmbZW8r+N/qQQHi/bn6YaN0yf835sfvBtvMjZgvqxlGSuIatMbey8mC16NhQ\r\n"
		~ "CDYpbzq3Vtq8iITNdfo2kCWA+5Tc9xAcvnM/xQgAvaizKkSZFSdIFn53xXaFaZLG\r\n"
		~ "jOQfWC4oHMvsBZhIa3Bu6pG1nAeC4h2YLXG6MpxvlTPwtEaP/nWHXUzM6uRaXW7s\r\n"
		~ "vBnG1ktB2srdBMWMORzRXTyKsJZ4QKtVsQeSXxacDjsI96H1KEotxJFckNu03Uf4\r\n"
		~ "J9u+F4H4UWqr3m26SZ2A4qnfo3s3HFcN1oakIGWOPDguIv7b1yqzBnIBGuZZjvv6\r\n"
		~ "hYPMV7HjCaKScoDhJG2ryHdj1XibH7M18elxaD/VaE6hZIAu/l/WElL3GzAqtGWX\r\n"
		~ "XtmpqedLOZHg8Fhsl8kdHuU+j+cZ8Bmitb0+rWpKI5RI8eZkWDU1N5hDaL2SNEAy\r\n"
		~ "oPEp6I6AtHO/jSig62kaia6PJGTLGDkIdhjJ6idNXBvBLAySUyE7gJ3y6ktFljSo\r\n"
		~ "T5dfiGkNWBPF8SliVxDeFahcFoLcpc4+phZaPXcXjhojwwAFkGsCGHu6dvKJNIwa\r\n"
		~ "JpZE31RPnFsCtZj55e0LZui8QfcqVWfGJyk1WiONN0flW6dOGgW3eOsL6IsCAwEA\r\n"
		~ "AQKCAgEAvntKfIc6wumEYhZkog153q0XDFSmMJj1OUSNfQrFMmocu9JZ1xs1PXaM\r\n"
		~ "pz1WgNa4y5cKM19wvQjsxyZPtf4DWLC2Zy3OyxY9llZsSyQh8lnSB8i8YTDE8ebI\r\n"
		~ "atTsYYaCXUOY0Hv7YbwsZjhGlnNgRxPRc37qIijEcSn7y2Zuq+2ZFtdw7Or7TuDU\r\n"
		~ "Q9U1omkSLhVviFljqO4dL8Uoqej4AnToWQMtYMaDDyI5MuiY/DXfGnfrC08NYd58\r\n"
		~ "1c/PcYUiEFa7ekVY6PXDTuTi4vAFiTOCoZ/b0aU28EPuK8tFLJT8wSYwB6y7Bgo9\r\n"
		~ "UMdoA3dLjnvIXg3lTIp7N3MEqUiWG3Ac2RBvds9/Aajn9hn6YtP9cqHQTf7rfaaY\r\n"
		~ "Jtlz6ZjXbqvZtQTd02/OlvvoKtOSqEg/y0WLGC/NQVtKB8Y8KCWtAGF6pmb3uciB\r\n"
		~ "9wbOS9F9o0ipigktPtgkeDTl9/1DV8h6oApAjnPW0r7mwXvT7twb+5+2GZ+h3jST\r\n"
		~ "IfHpcP+l7fobfltog7Jie+X49VFbuXWsCys1UBDDonGjRyS4eNQKylcGibhLBXU2\r\n"
		~ "iPgF86GNZUYG+T4kZQ3xOQdcPYqaU/GUar7Tm0p4HSvL3Jga2PoV9wfEKGzxnVBs\r\n"
		~ "9o6n3x7KoB4IX7oX4o2kpXv7KmzYfZUffeor55ecmDyErBOLA6ECggEBAPvOwCqP\r\n"
		~ "TW/fRST6St87S+wgjB2pTFlX+Jmi8v7lazlTnHhknx7FjV7G+x469uk3BL07QGjF\r\n"
		~ "2EVAn2n0vZm/TVmsYdT7Jkr2t3nO7zmUeQ9VpZhq/gnRkPSjRKj0lX6rlHXvgWnI\r\n"
		~ "rANdCIuCtltxI6dgpZ4FHWd+fAhOkoR01szadxeLMB0CfoBvCw26GIua6MOXEiP/\r\n"
		~ "jIC70B8VkmpbGra0qSoGrlVXGpQ1Q9SQLVuX+o0CS9bD3cZzm9Rsg98xEJx48q32\r\n"
		~ "ykxP7C/e5hDceUxHtjozlr6NDVNdY+pEp+mh0FOlkykcSpa7ra0chXBAxA+U4yRe\r\n"
		~ "yWEJDsVCC0PgYxkCggEBAPK7JA2oMwf2JpnuC/zrNgye/rNVlPFqvirvXQxDgGMN\r\n"
		~ "65aks/uRWDODhOCAs1KS83FUBBc4Agl0EbxafF8IAYg/VBIPMV8qpPMr0dFLrfT5\r\n"
		~ "+gXILVu/XltBGCXErFs66aiZTTargyfBIwBmlVGX+5XkCus4SeHNgv7Pj43rleRG\r\n"
		~ "eIx2lTgDoPjOFNMSxeMJkMLvTiwfiO953GViePBU5Hv/xdqJf3/0rd80T9SOv8gb\r\n"
		~ "HUn+ogb0YX/pglcEh7pjVrnuXSCvZP6fntN7IT3u247ReVE/nzOMzS+JXBiUi4XB\r\n"
		~ "57+a2oXDm2tnTjHy/l4KDIIHuhQGfUM5L6x2mboh4UMCggEBAOznVVA1RmuMKWdi\r\n"
		~ "u/JNvV5IOMrnLteXtmIFNoytlzV1/m4ebL3sqtaSakvEuewsQR8vkaeBC7oL1G9B\r\n"
		~ "POhbXRCS5/AS4bIBcBj/oX4Qu9y7fXJqptrh+XjP6pbylXt5PdG/JYg6rer0Kkfn\r\n"
		~ "EF3zkdG1UdvbgBCQpWzDT4Gi0zwkBYt2/iss34tB7apafSFK+taZWQ3ZLX0oNeQo\r\n"
		~ "zXmWgQmH6ueJJZdQvcbWXhysEKBt2eG0WVmTKSG+PsuZ1G+1n6U2/UrCNw2Y2+Ml\r\n"
		~ "2Fngs5Yamc0kIBziY7kc0hXjxf4+qNspmcxBu8MYi4ukm75CkLMAJrtfGiNa/DSF\r\n"
		~ "sEeJ4nECggEACoAD8D9NbdO9Gb2NcTRvkx4xoGpcVhErBspx+PzWifJpNYwMaR6B\r\n"
		~ "dUEEN335w+GtfEKJJsP6epQ1zDMR3D6Jam5q4ZkcpqQ+nHJR0j722HkT0ro1FBn0\r\n"
		~ "J/hp5gBbAFtNDkkLaQkEVGzrabIGVZBAhtxliIVX1NfCCenKqPX+9vABePoMPG8T\r\n"
		~ "wI+RoQvX2ZlpVLVraUc38jwQR6Z52tOhSqfm1CxMgql/9/7YUTaXnz1lB/Vm5uwd\r\n"
		~ "Z54fUEpW4L45WzOvfaF4ufcHtNhHuNkjUEtJdzVMWruFiL/lZv7OBkw8DTLSrySm\r\n"
		~ "DYBbhpefX0wJ/Hn/F6ysMINBx7Edt0qN5wKCAQEApvMWbJnjztZeN4mi5B+d4gSh\r\n"
		~ "HMcXZOtsjqS0IRocoXCNjzYJZjlR0kLdiV6uQSOWVXutcol4ZGyOeWnN3eTkD2xa\r\n"
		~ "1USPCgnlUIGEVSU5cBKdpDDY1nIdpt2ropXVGnN9wYq+k5ta+tQfc6G4DmlzQ6H1\r\n"
		~ "CNDTPEtvaZCfSpK1tWFwo3HrFmKFSEXl/5fkKOiv9h40uqTDdHkwCfi+s2YWxFp2\r\n"
		~ "BZEbOGC2MZIEpvbBi0CF6KZO752Zh3SPuj4puhrchOYSR5RO52IliPe4T1CTydES\r\n"
		~ "djc2isb0cYRPjWsoSEwnemqYeJM/jURB1UUPqKWMbuJhl3qHW3lxuzIugKHrWg==\r\n"
		~ "-----END RSA PRIVATE KEY-----\r\n";
	auto prvKeyDer = cast(immutable(ubyte)[])(x"3082092A" // SEQUENCE 2346 bytes
		~ x"0201"~x"00"     // INTEGER: version 0
		~ x"02820201"       // INTEGER: modulus (513 bytes = 0x00 + 512bytes)
			~ x"00EEC185251C857FC2EE89D4931F23D96646835257892FB6B42B687CCD0345947F"
			~ x"2D9CB8A1D0A64B6266D95BCAFE37FA904078BF6E7E9868DD327FCDF9B1FBC1B6"
			~ x"F323660BEAC65192B886AD31B7B2F260B5E8D8500836296F3AB756DABC8884CD"
			~ x"75FA36902580FB94DCF7101CBE733FC50800BDA8B32A4499152748167E77C576"
			~ x"856992C68CE41F582E281CCBEC0598486B706EEA91B59C0782E21D982D71BA32"
			~ x"9C6F9533F0B4468FFE75875D4CCCEAE45A5D6EECBC19C6D64B41DACADD04C58C"
			~ x"391CD15D3C8AB0967840AB55B107925F169C0E3B08F7A1F5284A2DC4915C90DB"
			~ x"B4DD47F827DBBE1781F8516AABDE6DBA499D80E2A9DFA37B371C570DD686A420"
			~ x"658E3C382E22FEDBD72AB30672011AE6598EFBFA8583CC57B1E309A2927280E1"
			~ x"246DABC87763D5789B1FB335F1E971683FD5684EA164802EFE5FD61252F71B30"
			~ x"2AB465975ED9A9A9E74B3991E0F0586C97C91D1EE53E8FE719F019A2B5BD3EAD"
			~ x"6A4A239448F1E66458353537984368BD92344032A0F129E88E80B473BF8D28A0"
			~ x"EB691A89AE8F2464CB1839087618C9EA274D5C1BC12C0C9253213B809DF2EA4B"
			~ x"459634A84F975F88690D5813C5F129625710DE15A85C1682DCA5CE3EA6165A3D"
			~ x"77178E1A23C30005906B02187BBA76F289348C1A269644DF544F9C5B02B598F9"
			~ x"E5ED0B66E8BC41F72A5567C62729355A238D3747E55BA74E1A05B778EB0BE88B"
		~ x"0203"~x"010001" // INTEGER: publicExponent (3 bytes)
		~ x"02820201"       // INTEGER: privateExponent (513 bytes = 0x00 + 512 bytes)
			~ x"00BE7B4A7C873AC2E984621664A20D79DEAD170C54A63098F539448D7D0AC5326A"
			~ x"1CBBD259D71B353D768CA73D5680D6B8CB970A335F70BD08ECC7264FB5FE0358"
			~ x"B0B6672DCECB163D96566C4B2421F259D207C8BC6130C4F1E6C86AD4EC618682"
			~ x"5D4398D07BFB61BC2C6638469673604713D1737EEA2228C47129FBCB666EABED"
			~ x"9916D770ECEAFB4EE0D443D535A269122E156F885963A8EE1D2FC528A9E8F802"
			~ x"74E859032D60C6830F223932E898FC35DF1A77EB0B4F0D61DE7CD5CFCF718522"
			~ x"1056BB7A4558E8F5C34EE4E2E2F005893382A19FDBD1A536F043EE2BCB452C94"
			~ x"FCC1263007ACBB060A3D50C76803774B8E7BC85E0DE54C8A7B377304A948961B"
			~ x"701CD9106F76CF7F01A8E7F619FA62D3FD72A1D04DFEEB7DA69826D973E998D7"
			~ x"6EABD9B504DDD36FCE96FBE82AD392A8483FCB458B182FCD415B4A07C63C2825"
			~ x"AD00617AA666F7B9C881F706CE4BD17DA348A98A092D3ED8247834E5F7FD4357"
			~ x"C87AA00A408E73D6D2BEE6C17BD3EEDC1BFB9FB6199FA1DE349321F1E970FFA5"
			~ x"EDFA1B7E5B6883B2627BE5F8F5515BB975AC0B2B355010C3A271A34724B878D4"
			~ x"0ACA570689B84B05753688F805F3A18D654606F93E24650DF139075C3D8A9A53"
			~ x"F1946ABED39B4A781D2BCBDC981AD8FA15F707C4286CF19D506CF68EA7DF1ECA"
			~ x"A01E085FBA17E28DA4A57BFB2A6CD87D951F7DEA2BE7979C983C84AC138B03A1"
		~ x"02820101"       // INTEGER: prime1 (257 bytes = 0x00 + 256 bytes)
			~ x"00FBCEC02A8F4D6FDF4524FA4ADF3B4BEC208C1DA94C5957F899A2F2FEE56B3953"
			~ x"9C78649F1EC58D5EC6FB1E3AF6E93704BD3B4068C5D845409F69F4BD99BF4D59"
			~ x"AC61D4FB264AF6B779CEEF3994790F55A5986AFE09D190F4A344A8F4957EAB94"
			~ x"75EF8169C8AC035D088B82B65B7123A760A59E051D677E7C084E928474D6CCDA"
			~ x"77178B301D027E806F0B0DBA188B9AE8C3971223FF8C80BBD01F15926A5B1AB6"
			~ x"B4A92A06AE55571A943543D4902D5B97FA8D024BD6C3DDC6739BD46C83DF3110"
			~ x"9C78F2ADF6CA4C4FEC2FDEE610DC794C47B63A3396BE8D0D535D63EA44A7E9A1"
			~ x"D053A593291C4A96BBADAD1C857040C40F94E3245EC961090EC5420B43E06319"
		~ x"02820101"       // INTEGER: prime2 (257 bytes = 0x00 + 256 bytes)
			~ x"00F2BB240DA83307F62699EE0BFCEB360C9EFEB35594F16ABE2AEF5D0C4380630D"
			~ x"EB96A4B3FB9158338384E080B35292F3715404173802097411BC5A7C5F080188"
			~ x"3F54120F315F2AA4F32BD1D14BADF4F9FA05C82D5BBF5E5B411825C4AC5B3AE9"
			~ x"A8994D36AB8327C1230066955197FB95E40AEB3849E1CD82FECF8F8DEB95E446"
			~ x"788C76953803A0F8CE14D312C5E30990C2EF4E2C1F88EF79DC656278F054E47B"
			~ x"FFC5DA897F7FF4ADDF344FD48EBFC81B1D49FEA206F4617FE982570487BA6356"
			~ x"B9EE5D20AF64FE9F9ED37B213DEEDB8ED179513F9F338CCD2F895C18948B85C1"
			~ x"E7BF9ADA85C39B6B674E31F2FE5E0A0C8207BA14067D43392FAC7699BA21E143"
		~ x"02820101"       // INTEGER: exponent1 (257 bytes = 0x00 + 256 bytes)
			~ x"00ECE7555035466B8C296762BBF24DBD5E4838CAE72ED797B66205368CAD973575"
			~ x"FE6E1E6CBDECAAD6926A4BC4B9EC2C411F2F91A7810BBA0BD46F413CE85B5D10"
			~ x"92E7F012E1B2017018FFA17E10BBDCBB7D726AA6DAE1F978CFEA96F2957B793D"
			~ x"D1BF25883AADEAF42A47E7105DF391D1B551DBDB801090A56CC34F81A2D33C24"
			~ x"058B76FE2B2CDF8B41EDAA5A7D214AFAD699590DD92D7D2835E428CD79968109"
			~ x"87EAE789259750BDC6D65E1CAC10A06DD9E1B45959932921BE3ECB99D46FB59F"
			~ x"A536FD4AC2370D98DBE325D859E0B3961A99CD24201CE263B91CD215E3C5FE3E"
			~ x"A8DB2999CC41BBC3188B8BA49BBE4290B30026BB5F1A235AFC3485B04789E271"
		~ x"02820100"       // INTEGER: exponent2 (256 bytes)
			~ x"0A8003F03F4D6DD3BD19BD8D71346F931E31A06A5C56112B06CA71F8FCD689F2"
			~ x"69358C0C691E81754104377DF9C3E1AD7C428926C3FA7A9435CC3311DC3E896A"
			~ x"6E6AE1991CA6A43E9C7251D23EF6D87913D2BA351419F427F869E6005B005B4D"
			~ x"0E490B690904546CEB69B20655904086DC65888557D4D7C209E9CAA8F5FEF6F0"
			~ x"0178FA0C3C6F13C08F91A10BD7D9996954B56B694737F23C1047A679DAD3A14A"
			~ x"A7E6D42C4C82A97FF7FED85136979F3D6507F566E6EC1D679E1F504A56E0BE39"
			~ x"5B33AF7DA178B9F707B4D847B8D923504B4977354C5ABB8588BFE566FECE064C"
			~ x"3C0D32D2AF24A60D805B86979F5F4C09FC79FF17ACAC308341C7B11DB74A8DE7"
		~ x"02820101"       // INTEGER: coefficient (257 bytes = 0x00 + 256 bytes)
			~ x"00A6F3166C99E3CED65E3789A2E41F9DE204A11CC71764EB6C8EA4B4211A1CA170"
			~ x"8D8F3609663951D242DD895EAE412396557BAD728978646C8E7969CDDDE4E40F"
			~ x"6C5AD5448F0A09E550818455253970129DA430D8D6721DA6DDABA295D51A737D"
			~ x"C18ABE939B5AFAD41F73A1B80E697343A1F508D0D33C4B6F69909F4A92B5B561"
			~ x"70A371EB1662854845E5FF97E428E8AFF61E34BAA4C374793009F8BEB36616C4"
			~ x"5A7605911B3860B6319204A6F6C18B4085E8A64EEF9D9987748FBA3E29BA1ADC"
			~ x"84E61247944EE7622588F7B84F5093C9D1127637368AC6F471844F8D6B28484C"
			~ x"277A6A9878933F8D4441D5450FA8A58C6EE261977A875B7971BB322E80A1EB5A"
		);
	auto prvKeyBin = cast(immutable(ubyte)[2308])(x""
		// INTEGER: modulus (512 bytes)
		~ x"EEC185251C857FC2EE89D4931F23D96646835257892FB6B42B687CCD0345947F"
		~ x"2D9CB8A1D0A64B6266D95BCAFE37FA904078BF6E7E9868DD327FCDF9B1FBC1B6"
		~ x"F323660BEAC65192B886AD31B7B2F260B5E8D8500836296F3AB756DABC8884CD"
		~ x"75FA36902580FB94DCF7101CBE733FC50800BDA8B32A4499152748167E77C576"
		~ x"856992C68CE41F582E281CCBEC0598486B706EEA91B59C0782E21D982D71BA32"
		~ x"9C6F9533F0B4468FFE75875D4CCCEAE45A5D6EECBC19C6D64B41DACADD04C58C"
		~ x"391CD15D3C8AB0967840AB55B107925F169C0E3B08F7A1F5284A2DC4915C90DB"
		~ x"B4DD47F827DBBE1781F8516AABDE6DBA499D80E2A9DFA37B371C570DD686A420"
		~ x"658E3C382E22FEDBD72AB30672011AE6598EFBFA8583CC57B1E309A2927280E1"
		~ x"246DABC87763D5789B1FB335F1E971683FD5684EA164802EFE5FD61252F71B30"
		~ x"2AB465975ED9A9A9E74B3991E0F0586C97C91D1EE53E8FE719F019A2B5BD3EAD"
		~ x"6A4A239448F1E66458353537984368BD92344032A0F129E88E80B473BF8D28A0"
		~ x"EB691A89AE8F2464CB1839087618C9EA274D5C1BC12C0C9253213B809DF2EA4B"
		~ x"459634A84F975F88690D5813C5F129625710DE15A85C1682DCA5CE3EA6165A3D"
		~ x"77178E1A23C30005906B02187BBA76F289348C1A269644DF544F9C5B02B598F9"
		~ x"E5ED0B66E8BC41F72A5567C62729355A238D3747E55BA74E1A05B778EB0BE88B"
		// INTEGER: publicExponent (4 bytes)
		~ x"00010001"
		// INTEGER: privateExponent (512 bytes)
		~ x"BE7B4A7C873AC2E984621664A20D79DEAD170C54A63098F539448D7D0AC5326A"
		~ x"1CBBD259D71B353D768CA73D5680D6B8CB970A335F70BD08ECC7264FB5FE0358"
		~ x"B0B6672DCECB163D96566C4B2421F259D207C8BC6130C4F1E6C86AD4EC618682"
		~ x"5D4398D07BFB61BC2C6638469673604713D1737EEA2228C47129FBCB666EABED"
		~ x"9916D770ECEAFB4EE0D443D535A269122E156F885963A8EE1D2FC528A9E8F802"
		~ x"74E859032D60C6830F223932E898FC35DF1A77EB0B4F0D61DE7CD5CFCF718522"
		~ x"1056BB7A4558E8F5C34EE4E2E2F005893382A19FDBD1A536F043EE2BCB452C94"
		~ x"FCC1263007ACBB060A3D50C76803774B8E7BC85E0DE54C8A7B377304A948961B"
		~ x"701CD9106F76CF7F01A8E7F619FA62D3FD72A1D04DFEEB7DA69826D973E998D7"
		~ x"6EABD9B504DDD36FCE96FBE82AD392A8483FCB458B182FCD415B4A07C63C2825"
		~ x"AD00617AA666F7B9C881F706CE4BD17DA348A98A092D3ED8247834E5F7FD4357"
		~ x"C87AA00A408E73D6D2BEE6C17BD3EEDC1BFB9FB6199FA1DE349321F1E970FFA5"
		~ x"EDFA1B7E5B6883B2627BE5F8F5515BB975AC0B2B355010C3A271A34724B878D4"
		~ x"0ACA570689B84B05753688F805F3A18D654606F93E24650DF139075C3D8A9A53"
		~ x"F1946ABED39B4A781D2BCBDC981AD8FA15F707C4286CF19D506CF68EA7DF1ECA"
		~ x"A01E085FBA17E28DA4A57BFB2A6CD87D951F7DEA2BE7979C983C84AC138B03A1"
		// INTEGER: prime1 (256 bytes)
		~ x"FBCEC02A8F4D6FDF4524FA4ADF3B4BEC208C1DA94C5957F899A2F2FEE56B3953"
		~ x"9C78649F1EC58D5EC6FB1E3AF6E93704BD3B4068C5D845409F69F4BD99BF4D59"
		~ x"AC61D4FB264AF6B779CEEF3994790F55A5986AFE09D190F4A344A8F4957EAB94"
		~ x"75EF8169C8AC035D088B82B65B7123A760A59E051D677E7C084E928474D6CCDA"
		~ x"77178B301D027E806F0B0DBA188B9AE8C3971223FF8C80BBD01F15926A5B1AB6"
		~ x"B4A92A06AE55571A943543D4902D5B97FA8D024BD6C3DDC6739BD46C83DF3110"
		~ x"9C78F2ADF6CA4C4FEC2FDEE610DC794C47B63A3396BE8D0D535D63EA44A7E9A1"
		~ x"D053A593291C4A96BBADAD1C857040C40F94E3245EC961090EC5420B43E06319"
		// INTEGER: prime2 (256 bytes)
		~ x"F2BB240DA83307F62699EE0BFCEB360C9EFEB35594F16ABE2AEF5D0C4380630D"
		~ x"EB96A4B3FB9158338384E080B35292F3715404173802097411BC5A7C5F080188"
		~ x"3F54120F315F2AA4F32BD1D14BADF4F9FA05C82D5BBF5E5B411825C4AC5B3AE9"
		~ x"A8994D36AB8327C1230066955197FB95E40AEB3849E1CD82FECF8F8DEB95E446"
		~ x"788C76953803A0F8CE14D312C5E30990C2EF4E2C1F88EF79DC656278F054E47B"
		~ x"FFC5DA897F7FF4ADDF344FD48EBFC81B1D49FEA206F4617FE982570487BA6356"
		~ x"B9EE5D20AF64FE9F9ED37B213DEEDB8ED179513F9F338CCD2F895C18948B85C1"
		~ x"E7BF9ADA85C39B6B674E31F2FE5E0A0C8207BA14067D43392FAC7699BA21E143"
		// INTEGER: exponent1 (256 bytes)
		~ x"ECE7555035466B8C296762BBF24DBD5E4838CAE72ED797B66205368CAD973575"
		~ x"FE6E1E6CBDECAAD6926A4BC4B9EC2C411F2F91A7810BBA0BD46F413CE85B5D10"
		~ x"92E7F012E1B2017018FFA17E10BBDCBB7D726AA6DAE1F978CFEA96F2957B793D"
		~ x"D1BF25883AADEAF42A47E7105DF391D1B551DBDB801090A56CC34F81A2D33C24"
		~ x"058B76FE2B2CDF8B41EDAA5A7D214AFAD699590DD92D7D2835E428CD79968109"
		~ x"87EAE789259750BDC6D65E1CAC10A06DD9E1B45959932921BE3ECB99D46FB59F"
		~ x"A536FD4AC2370D98DBE325D859E0B3961A99CD24201CE263B91CD215E3C5FE3E"
		~ x"A8DB2999CC41BBC3188B8BA49BBE4290B30026BB5F1A235AFC3485B04789E271"
		// INTEGER: exponent2 (256 bytes)
		~ x"0A8003F03F4D6DD3BD19BD8D71346F931E31A06A5C56112B06CA71F8FCD689F2"
		~ x"69358C0C691E81754104377DF9C3E1AD7C428926C3FA7A9435CC3311DC3E896A"
		~ x"6E6AE1991CA6A43E9C7251D23EF6D87913D2BA351419F427F869E6005B005B4D"
		~ x"0E490B690904546CEB69B20655904086DC65888557D4D7C209E9CAA8F5FEF6F0"
		~ x"0178FA0C3C6F13C08F91A10BD7D9996954B56B694737F23C1047A679DAD3A14A"
		~ x"A7E6D42C4C82A97FF7FED85136979F3D6507F566E6EC1D679E1F504A56E0BE39"
		~ x"5B33AF7DA178B9F707B4D847B8D923504B4977354C5ABB8588BFE566FECE064C"
		~ x"3C0D32D2AF24A60D805B86979F5F4C09FC79FF17ACAC308341C7B11DB74A8DE7"
		// INTEGER: coefficient (256 bytes)
		~ x"A6F3166C99E3CED65E3789A2E41F9DE204A11CC71764EB6C8EA4B4211A1CA170"
		~ x"8D8F3609663951D242DD895EAE412396557BAD728978646C8E7969CDDDE4E40F"
		~ x"6C5AD5448F0A09E550818455253970129DA430D8D6721DA6DDABA295D51A737D"
		~ x"C18ABE939B5AFAD41F73A1B80E697343A1F508D0D33C4B6F69909F4A92B5B561"
		~ x"70A371EB1662854845E5FF97E428E8AFF61E34BAA4C374793009F8BEB36616C4"
		~ x"5A7605911B3860B6319204A6F6C18B4085E8A64EEF9D9987748FBA3E29BA1ADC"
		~ x"84E61247944EE7622588F7B84F5093C9D1127637368AC6F471844F8D6B28484C"
		~ x"277A6A9878933F8D4441D5450FA8A58C6EE261977A875B7971BB322E80A1EB5A"
		);
	// openssl rsa -in private_key_rsa4096.pem -pubout -out -
	auto pubKeyPem = "-----BEGIN PUBLIC KEY-----\r\n"
		~ "MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA7sGFJRyFf8LuidSTHyPZ\r\n"
		~ "ZkaDUleJL7a0K2h8zQNFlH8tnLih0KZLYmbZW8r+N/qQQHi/bn6YaN0yf835sfvB\r\n"
		~ "tvMjZgvqxlGSuIatMbey8mC16NhQCDYpbzq3Vtq8iITNdfo2kCWA+5Tc9xAcvnM/\r\n"
		~ "xQgAvaizKkSZFSdIFn53xXaFaZLGjOQfWC4oHMvsBZhIa3Bu6pG1nAeC4h2YLXG6\r\n"
		~ "MpxvlTPwtEaP/nWHXUzM6uRaXW7svBnG1ktB2srdBMWMORzRXTyKsJZ4QKtVsQeS\r\n"
		~ "XxacDjsI96H1KEotxJFckNu03Uf4J9u+F4H4UWqr3m26SZ2A4qnfo3s3HFcN1oak\r\n"
		~ "IGWOPDguIv7b1yqzBnIBGuZZjvv6hYPMV7HjCaKScoDhJG2ryHdj1XibH7M18elx\r\n"
		~ "aD/VaE6hZIAu/l/WElL3GzAqtGWXXtmpqedLOZHg8Fhsl8kdHuU+j+cZ8Bmitb0+\r\n"
		~ "rWpKI5RI8eZkWDU1N5hDaL2SNEAyoPEp6I6AtHO/jSig62kaia6PJGTLGDkIdhjJ\r\n"
		~ "6idNXBvBLAySUyE7gJ3y6ktFljSoT5dfiGkNWBPF8SliVxDeFahcFoLcpc4+phZa\r\n"
		~ "PXcXjhojwwAFkGsCGHu6dvKJNIwaJpZE31RPnFsCtZj55e0LZui8QfcqVWfGJyk1\r\n"
		~ "WiONN0flW6dOGgW3eOsL6IsCAwEAAQ==\r\n"
		~ "-----END PUBLIC KEY-----\r\n";
	auto pubKeyDer = cast(immutable(ubyte)[])(x"30820222"        // SEQUENCE (546 bytes)
		~ x"300d"~x"06092a864886f70d0101010500" // SEQUENCE (13 bytes) / OID rsaEncryption
		~ x"0382020f00"                 // BIT STRING (527 bytes / 0bits)
			~ x"3082020a"                   // SEQUENCE (522)
				~ x"02820201"                   // INTEGER: modulus (513 bytes)
					~ x"00eec185251c857fc2ee89d4931f23d96646835257892fb6b42b687ccd0345947f"
					~ x"2d9cb8a1d0a64b6266d95bcafe37fa904078bf6e7e9868dd327fcdf9b1fbc1b6"
					~ x"f323660beac65192b886ad31b7b2f260b5e8d8500836296f3ab756dabc8884cd"
					~ x"75fa36902580fb94dcf7101cbe733fc50800bda8b32a4499152748167e77c576"
					~ x"856992c68ce41f582e281ccbec0598486b706eea91b59c0782e21d982d71ba32"
					~ x"9c6f9533f0b4468ffe75875d4ccceae45a5d6eecbc19c6d64b41dacadd04c58c"
					~ x"391cd15d3c8ab0967840ab55b107925f169c0e3b08f7a1f5284a2dc4915c90db"
					~ x"b4dd47f827dbbe1781f8516aabde6dba499d80e2a9dfa37b371c570dd686a420"
					~ x"658e3c382e22fedbd72ab30672011ae6598efbfa8583cc57b1e309a2927280e1"
					~ x"246dabc87763d5789b1fb335f1e971683fd5684ea164802efe5fd61252f71b30"
					~ x"2ab465975ed9a9a9e74b3991e0f0586c97c91d1ee53e8fe719f019a2b5bd3ead"
					~ x"6a4a239448f1e66458353537984368bd92344032a0f129e88e80b473bf8d28a0"
					~ x"eb691a89ae8f2464cb1839087618c9ea274d5c1bc12c0c9253213b809df2ea4b"
					~ x"459634a84f975f88690d5813c5f129625710de15a85c1682dca5ce3ea6165a3d"
					~ x"77178e1a23c30005906b02187bba76f289348c1a269644df544f9c5b02b598f9"
					~ x"e5ed0b66e8bc41f72a5567c62729355a238d3747e55ba74e1a05b778eb0be88b"
				~ x"0203"~x"010001"             // INTEGER: publicExponent (3 bytes)
		);
	auto pubKeyBin = cast(immutable(ubyte)[516])(x""
		// INTEGER: modulus (512 bytes)
		~ x"eec185251c857fc2ee89d4931f23d96646835257892fb6b42b687ccd0345947f"
		~ x"2d9cb8a1d0a64b6266d95bcafe37fa904078bf6e7e9868dd327fcdf9b1fbc1b6"
		~ x"f323660beac65192b886ad31b7b2f260b5e8d8500836296f3ab756dabc8884cd"
		~ x"75fa36902580fb94dcf7101cbe733fc50800bda8b32a4499152748167e77c576"
		~ x"856992c68ce41f582e281ccbec0598486b706eea91b59c0782e21d982d71ba32"
		~ x"9c6f9533f0b4468ffe75875d4ccceae45a5d6eecbc19c6d64b41dacadd04c58c"
		~ x"391cd15d3c8ab0967840ab55b107925f169c0e3b08f7a1f5284a2dc4915c90db"
		~ x"b4dd47f827dbbe1781f8516aabde6dba499d80e2a9dfa37b371c570dd686a420"
		~ x"658e3c382e22fedbd72ab30672011ae6598efbfa8583cc57b1e309a2927280e1"
		~ x"246dabc87763d5789b1fb335f1e971683fd5684ea164802efe5fd61252f71b30"
		~ x"2ab465975ed9a9a9e74b3991e0f0586c97c91d1ee53e8fe719f019a2b5bd3ead"
		~ x"6a4a239448f1e66458353537984368bd92344032a0f129e88e80b473bf8d28a0"
		~ x"eb691a89ae8f2464cb1839087618c9ea274d5c1bc12c0c9253213b809df2ea4b"
		~ x"459634a84f975f88690d5813c5f129625710de15a85c1682dca5ce3ea6165a3d"
		~ x"77178e1a23c30005906b02187bba76f289348c1a269644df544f9c5b02b598f9"
		~ x"e5ed0b66e8bc41f72a5567c62729355a238d3747e55ba74e1a05b778eb0be88b"
		// INTEGER: publicExponent (4 bytes)
		~ x"00010001"
		);
	// openssl pkeyutl -sign -inkey private_key_rsa4096.pem -in test.txt -out -
	auto signatureExample1 = cast(immutable(ubyte)[])(x""
		~ x"8c4d1661b50749b7e54554204697d0dd99b54fe37cbbc25a012065723fb126f4"
		~ x"a94a81c5a7bf4f8e3bd63224b036857e2e1b0ffb74581b054037ce48430356fb"
		~ x"c7018314f845570cddad47040183ec8ce88a52a1b8ed3c430c7b37bfb547eb86"
		~ x"2fb52c802e7e1b4e643a55655d5ecc3f8a4dd6cbf6fde01cf1e30106d5c4942a"
		~ x"3d29201d96b96da49f7bb2b3d741fb80ba6f3dbd20304f7c76778951c1a5a08f"
		~ x"0ed1a74988664987c4f5e9b63a4e5927dbb57a09c45a0380c685aa26a25cbb1d"
		~ x"451d54d6842098eab816f2f84845d454d64218cda4a8d09b17394958cc0d0834"
		~ x"a1273af4a7ef07bb387ada53515a2c69735ec8bdf731032deb34d97490570e9f"
		~ x"7a72967fd456efd69fafc93f0d087a7be9cd62a5756023b14e0edc6aa3f9eabc"
		~ x"6e52a8a41a6b6705ecdb5ab26b1c2866b9c1a464f0c85fd8230fe9ad4bd4b7b8"
		~ x"963deda74470f0b2d7ee1c859264a5b727bf0df9374ccde04517c3905e0f6eee"
		~ x"eddd1e500ed373b2a163b4283e4d74b48743c51e70445771e793233493df7070"
		~ x"794cda111a9102acfe4aacd4dea31a8d742e4be5e21ca9809089f55f3172fffb"
		~ x"89f6356943565db8da1abded93381495fca6ddcb584fc3cca3dbd683f2e8dbbb"
		~ x"bf2cec673f9704f8d6ef53faf4565c2137b646b58918ce03894d187de56d30ee"
		~ x"68c07e3e0e9177f804595726e61d3f44d8993a192c48470d6003e894edebd500");
	// openssl dgst -sha256 -binary test.txt | openssl pkeyutl -sign -inkey private_key_rsa4096.pem -out sign_rsa.bin
	// openssl dgst -sha256 -binary test.txt | openssl pkeyutl -verify -pubin -inkey public_key_rsa4096.pem -sigfile sign_rsa.bin
	auto signaturePhSHA256Example1 = cast(immutable(ubyte)[])(x""
		~ x"BBBB37C625DD3D17BA76E657C82D8781EA5CF0C877A001FEC9C35E37B47CD82F"
		~ x"45F7AA876705FB0BCF14B5850EDC7A832AD824F1E4170F04680F2AF4691FCF41"
		~ x"FABCB9C01EBBB7DE038F203EF7E433EF01454054798262DC1B0FC04C97DE6DEE"
		~ x"E804E0A598F76FF44936F1304D5DA41D9BBB3FD1FE2E74FF841A17280476C170"
		~ x"260D76F5245D101E453BAAEA115053F2F352889067F07A8A0496C16A284E3E4D"
		~ x"1B0FC6BCF7AA88B0722D122B256EF5C95FB63EB9972134141E626A9B53F8ACC3"
		~ x"1C73DD2B1CFE358ACC0EA64C6070C8005B1B30B54185380F1D94C7EC97550DD4"
		~ x"992B52B529FF58374008F8D6F8DB7C31B0A49227EC7BDA8E78384C6346692FEA"
		~ x"A7AFE2DCE6F1EFCE20C891A38F90CC9E7C2DC0CDD18D53380101E8B2DD645E0D"
		~ x"5A4D786F7FE84AA358B3AA307258941B10F5C6A2D0E5844FE19153B5B0FAB1CD"
		~ x"8B327F3F2502D8065611F35D4CF42B2829A142B0FD21AE9F89F892537D46050C"
		~ x"D4767614FB6D4361DB71AD6597650DC806FF92BB0EA2CB6C2AA698D4E5F63D2C"
		~ x"2CF58D87494D18AC537F3152040C2526A02BFB22D67092E5F3701D8AB7C52A85"
		~ x"2A6E25D323C1FB736C57605619EF2E307F113FECFBF2741ED7C89E23DA6C7B16"
		~ x"AF64B649D9C17D6F8E2C08904E6F7353020E0F141BE8F77B59229FCA876B901B"
		~ x"71DE27C2A95C5473C18AC7BA27802A38EE129F4F7DC9D55D8095D1E8CC2CCD65");
	// openssl dgst -sha256 -sign private_key_rsa4096.pem -out - test.txt
	// openssl dgst -sha256 -verify public_key_rsa4096.pem -signature - test.txt
	auto signaturePhSHA256Example2 = cast(immutable(ubyte)[])(x""
		~ x"b3d5263a36ad17931b18a791011f604873d2e03a94414d978b0dda9f56ce1c5b"
		~ x"01a209aa783544d0ef586f64ce0afbffd05ff987ebc3fcda706a90b43a54039b"
		~ x"14a62f578dd9f7872a4479dbcc1d596033bbf27df54a2e2367f3d86fdd5b5ad5"
		~ x"421ffadfd87dbe2de9c57f1d96e80b559cc0e4c936499d1697677449be619277"
		~ x"d4018323dc1119d5283ad504cb498d39951fc9ae5a030eb99caa0ad566164c7f"
		~ x"dc0a40e0cfe01104eb66df5c2afcea4c01c6e3d5eaf5655bc6ba597763c389dc"
		~ x"55b7a9640e2ac3abc0a2500b54785856bc16d964d88aeb9da92363840bbaadb7"
		~ x"86ae60de9836697d4d07180622ef5345cb22919c6e0d2905e6aaea466c6ef185"
		~ x"19499442e1fd6178f5199b53c2fba3334867ff7af753e2256918143483150d60"
		~ x"0491a6172f99282137e589ea38f0e35a93bcf66d6db95edd588769067d95da11"
		~ x"dbd9d0da46a2cc68e54addf29a10ca5ce8b5ef40626769307a1686f069c03163"
		~ x"0732f448c08421acb7fb20b779ad1e57668541193b6f9abae1e9ba1d0a86ab66"
		~ x"8d4d0cd949cc59a6f8263d65b01a836be51989afd5118de20d458be31633194d"
		~ x"500b8117b9f2fd7f82bacffc8a821906b2f4b9a6f06212fb10fde3c15176a58e"
		~ x"d010d927dbe41336f965b7e4f5a82d0f11908834d0c3d95c95648a2e5a80a894"
		~ x"99beb6009620a34d582531ba88a9f003d020d8ebecf80cb723134e94032a5101");
	enum message = "Hello, World!";
	
	alias Engine = BcryptRSA4096Engine;
	// 自分で生成して各種検証
	auto prvKey = Engine.PrivateKey.createKey();
	auto pubKey = Engine.PublicKey.createKey(prvKey);
	
	auto signer = Signer!Engine(prvKey.toPEM);
	signer.update(message.representation);
	auto signature = signer.sign();
	auto verifier = Verifier!Engine(pubKey.toPEM);
	verifier.update(message.representation);
	assert(verifier.verify(signature));
	auto encrypter = Encrypter!Engine(pubKey.toPEM);
	auto encrypted = encrypter.encrypt(message.representation);
	auto decrypter = Decrypter!Engine(prvKey.toPEM);
	auto decrypted = decrypter.decrypt(encrypted);
	assert(decrypted == message.representation);
	
	// 事前準備したデータでの検証
	auto prvKey1 = Engine.PrivateKey.fromPEM(prvKeyPem);
	assert(prvKey1.toPEM().splitLines == prvKeyPem.splitLines);
	assert(prvKey1.toDER() == prvKeyDer);
	assert(prvKey1.toBinary() == prvKeyBin);
	auto prvKey2 = Engine.PrivateKey.fromDER(prvKeyDer);
	assert(prvKey2.toPEM().splitLines == prvKeyPem.splitLines);
	assert(prvKey2.toDER() == prvKeyDer);
	assert(prvKey2.toBinary() == prvKeyBin);
	auto prvKey3 = Engine.PrivateKey.fromBinary(prvKeyBin);
	assert(prvKey3.toPEM().splitLines == prvKeyPem.splitLines);
	assert(prvKey3.toDER() == prvKeyDer);
	assert(prvKey3.toBinary() == prvKeyBin);
	
	auto pubKey1 = Engine.PublicKey.fromPEM(pubKeyPem);
	assert(pubKey1.toPEM().splitLines == pubKeyPem.splitLines);
	assert(pubKey1.toDER() == pubKeyDer);
	assert(pubKey1.toBinary() == pubKeyBin);
	auto pubKey2 = Engine.PublicKey.fromDER(pubKeyDer);
	assert(pubKey2.toPEM().splitLines == pubKeyPem.splitLines);
	assert(pubKey2.toDER() == pubKeyDer);
	assert(pubKey2.toBinary() == pubKeyBin);
	auto pubKey3 = Engine.PublicKey.fromBinary(pubKeyBin);
	assert(pubKey3.toPEM().splitLines == pubKeyPem.splitLines);
	assert(pubKey3.toDER() == pubKeyDer);
	assert(pubKey3.toBinary() == pubKeyBin);
	auto pubKey4 = Engine.PublicKey.createKey(prvKey1);
	assert(pubKey4.toPEM().splitLines == pubKeyPem.splitLines);
	assert(pubKey4.toDER() == pubKeyDer);
	assert(pubKey4.toBinary() == pubKeyBin);
	
	// 署名
	auto signer1 = Signer!Engine(prvKey1.toBinary);
	signer1.update(message.representation);
	auto signature1 = signer1.sign();
	assert(signature1[] == signatureExample1[]);
	
	// 検証
	auto verifier1 = Verifier!Engine(pubKey1.toBinary);
	verifier1.update(message.representation);
	assert(verifier1.verify(signature1));
	assert(verifier1.verify(signatureExample1));
	
	// 署名(プリハッシュ)
	auto signer2 = Signer!(Engine, SHA256)(prvKey1.toBinary);
	signer2.update(message.representation);
	auto signature2 = signer2.sign();
	assert(signature2[] == signaturePhSHA256Example1[]);
	
	// 検証(プリハッシュ)
	auto verifier2 = Verifier!(Engine, SHA256)(pubKey1.toBinary);
	verifier2.update(message.representation);
	assert(verifier2.verify(signature2));
	assert(verifier2.verify(signaturePhSHA256Example1));
	
	// 暗号化
	auto encrypter1 = Encrypter!Engine(pubKey1.toPEM);
	auto encrypted1 = encrypter.encrypt(message.representation);
	
	// 復号
	auto decrypter1 = Decrypter!Engine(prvKey1.toPEM);
	auto decrypted1 = decrypter.decrypt(encrypted1);
	assert(decrypted1 == message.representation);
}
// RSA 4096 for OpenSSL Command line
static if (enableOpenSSLCmdEngines) @system unittest
{
	import std.string;
	if (!isCommandExisting(defaultOpenSSLCommand))
		return;
	// openssl genrsa 4096 2>/dev/null
	auto prvKeyPem = "-----BEGIN RSA PRIVATE KEY-----\r\n"
		~ "MIIJKgIBAAKCAgEA7sGFJRyFf8LuidSTHyPZZkaDUleJL7a0K2h8zQNFlH8tnLih\r\n"
		~ "0KZLYmbZW8r+N/qQQHi/bn6YaN0yf835sfvBtvMjZgvqxlGSuIatMbey8mC16NhQ\r\n"
		~ "CDYpbzq3Vtq8iITNdfo2kCWA+5Tc9xAcvnM/xQgAvaizKkSZFSdIFn53xXaFaZLG\r\n"
		~ "jOQfWC4oHMvsBZhIa3Bu6pG1nAeC4h2YLXG6MpxvlTPwtEaP/nWHXUzM6uRaXW7s\r\n"
		~ "vBnG1ktB2srdBMWMORzRXTyKsJZ4QKtVsQeSXxacDjsI96H1KEotxJFckNu03Uf4\r\n"
		~ "J9u+F4H4UWqr3m26SZ2A4qnfo3s3HFcN1oakIGWOPDguIv7b1yqzBnIBGuZZjvv6\r\n"
		~ "hYPMV7HjCaKScoDhJG2ryHdj1XibH7M18elxaD/VaE6hZIAu/l/WElL3GzAqtGWX\r\n"
		~ "XtmpqedLOZHg8Fhsl8kdHuU+j+cZ8Bmitb0+rWpKI5RI8eZkWDU1N5hDaL2SNEAy\r\n"
		~ "oPEp6I6AtHO/jSig62kaia6PJGTLGDkIdhjJ6idNXBvBLAySUyE7gJ3y6ktFljSo\r\n"
		~ "T5dfiGkNWBPF8SliVxDeFahcFoLcpc4+phZaPXcXjhojwwAFkGsCGHu6dvKJNIwa\r\n"
		~ "JpZE31RPnFsCtZj55e0LZui8QfcqVWfGJyk1WiONN0flW6dOGgW3eOsL6IsCAwEA\r\n"
		~ "AQKCAgEAvntKfIc6wumEYhZkog153q0XDFSmMJj1OUSNfQrFMmocu9JZ1xs1PXaM\r\n"
		~ "pz1WgNa4y5cKM19wvQjsxyZPtf4DWLC2Zy3OyxY9llZsSyQh8lnSB8i8YTDE8ebI\r\n"
		~ "atTsYYaCXUOY0Hv7YbwsZjhGlnNgRxPRc37qIijEcSn7y2Zuq+2ZFtdw7Or7TuDU\r\n"
		~ "Q9U1omkSLhVviFljqO4dL8Uoqej4AnToWQMtYMaDDyI5MuiY/DXfGnfrC08NYd58\r\n"
		~ "1c/PcYUiEFa7ekVY6PXDTuTi4vAFiTOCoZ/b0aU28EPuK8tFLJT8wSYwB6y7Bgo9\r\n"
		~ "UMdoA3dLjnvIXg3lTIp7N3MEqUiWG3Ac2RBvds9/Aajn9hn6YtP9cqHQTf7rfaaY\r\n"
		~ "Jtlz6ZjXbqvZtQTd02/OlvvoKtOSqEg/y0WLGC/NQVtKB8Y8KCWtAGF6pmb3uciB\r\n"
		~ "9wbOS9F9o0ipigktPtgkeDTl9/1DV8h6oApAjnPW0r7mwXvT7twb+5+2GZ+h3jST\r\n"
		~ "IfHpcP+l7fobfltog7Jie+X49VFbuXWsCys1UBDDonGjRyS4eNQKylcGibhLBXU2\r\n"
		~ "iPgF86GNZUYG+T4kZQ3xOQdcPYqaU/GUar7Tm0p4HSvL3Jga2PoV9wfEKGzxnVBs\r\n"
		~ "9o6n3x7KoB4IX7oX4o2kpXv7KmzYfZUffeor55ecmDyErBOLA6ECggEBAPvOwCqP\r\n"
		~ "TW/fRST6St87S+wgjB2pTFlX+Jmi8v7lazlTnHhknx7FjV7G+x469uk3BL07QGjF\r\n"
		~ "2EVAn2n0vZm/TVmsYdT7Jkr2t3nO7zmUeQ9VpZhq/gnRkPSjRKj0lX6rlHXvgWnI\r\n"
		~ "rANdCIuCtltxI6dgpZ4FHWd+fAhOkoR01szadxeLMB0CfoBvCw26GIua6MOXEiP/\r\n"
		~ "jIC70B8VkmpbGra0qSoGrlVXGpQ1Q9SQLVuX+o0CS9bD3cZzm9Rsg98xEJx48q32\r\n"
		~ "ykxP7C/e5hDceUxHtjozlr6NDVNdY+pEp+mh0FOlkykcSpa7ra0chXBAxA+U4yRe\r\n"
		~ "yWEJDsVCC0PgYxkCggEBAPK7JA2oMwf2JpnuC/zrNgye/rNVlPFqvirvXQxDgGMN\r\n"
		~ "65aks/uRWDODhOCAs1KS83FUBBc4Agl0EbxafF8IAYg/VBIPMV8qpPMr0dFLrfT5\r\n"
		~ "+gXILVu/XltBGCXErFs66aiZTTargyfBIwBmlVGX+5XkCus4SeHNgv7Pj43rleRG\r\n"
		~ "eIx2lTgDoPjOFNMSxeMJkMLvTiwfiO953GViePBU5Hv/xdqJf3/0rd80T9SOv8gb\r\n"
		~ "HUn+ogb0YX/pglcEh7pjVrnuXSCvZP6fntN7IT3u247ReVE/nzOMzS+JXBiUi4XB\r\n"
		~ "57+a2oXDm2tnTjHy/l4KDIIHuhQGfUM5L6x2mboh4UMCggEBAOznVVA1RmuMKWdi\r\n"
		~ "u/JNvV5IOMrnLteXtmIFNoytlzV1/m4ebL3sqtaSakvEuewsQR8vkaeBC7oL1G9B\r\n"
		~ "POhbXRCS5/AS4bIBcBj/oX4Qu9y7fXJqptrh+XjP6pbylXt5PdG/JYg6rer0Kkfn\r\n"
		~ "EF3zkdG1UdvbgBCQpWzDT4Gi0zwkBYt2/iss34tB7apafSFK+taZWQ3ZLX0oNeQo\r\n"
		~ "zXmWgQmH6ueJJZdQvcbWXhysEKBt2eG0WVmTKSG+PsuZ1G+1n6U2/UrCNw2Y2+Ml\r\n"
		~ "2Fngs5Yamc0kIBziY7kc0hXjxf4+qNspmcxBu8MYi4ukm75CkLMAJrtfGiNa/DSF\r\n"
		~ "sEeJ4nECggEACoAD8D9NbdO9Gb2NcTRvkx4xoGpcVhErBspx+PzWifJpNYwMaR6B\r\n"
		~ "dUEEN335w+GtfEKJJsP6epQ1zDMR3D6Jam5q4ZkcpqQ+nHJR0j722HkT0ro1FBn0\r\n"
		~ "J/hp5gBbAFtNDkkLaQkEVGzrabIGVZBAhtxliIVX1NfCCenKqPX+9vABePoMPG8T\r\n"
		~ "wI+RoQvX2ZlpVLVraUc38jwQR6Z52tOhSqfm1CxMgql/9/7YUTaXnz1lB/Vm5uwd\r\n"
		~ "Z54fUEpW4L45WzOvfaF4ufcHtNhHuNkjUEtJdzVMWruFiL/lZv7OBkw8DTLSrySm\r\n"
		~ "DYBbhpefX0wJ/Hn/F6ysMINBx7Edt0qN5wKCAQEApvMWbJnjztZeN4mi5B+d4gSh\r\n"
		~ "HMcXZOtsjqS0IRocoXCNjzYJZjlR0kLdiV6uQSOWVXutcol4ZGyOeWnN3eTkD2xa\r\n"
		~ "1USPCgnlUIGEVSU5cBKdpDDY1nIdpt2ropXVGnN9wYq+k5ta+tQfc6G4DmlzQ6H1\r\n"
		~ "CNDTPEtvaZCfSpK1tWFwo3HrFmKFSEXl/5fkKOiv9h40uqTDdHkwCfi+s2YWxFp2\r\n"
		~ "BZEbOGC2MZIEpvbBi0CF6KZO752Zh3SPuj4puhrchOYSR5RO52IliPe4T1CTydES\r\n"
		~ "djc2isb0cYRPjWsoSEwnemqYeJM/jURB1UUPqKWMbuJhl3qHW3lxuzIugKHrWg==\r\n"
		~ "-----END RSA PRIVATE KEY-----\r\n";
	auto prvKeyDer = cast(immutable(ubyte)[])(x"3082092A" // SEQUENCE 2346 bytes
		~ x"0201"~x"00"     // INTEGER: version 0
		~ x"02820201"       // INTEGER: modulus (513 bytes = 0x00 + 512bytes)
			~ x"00EEC185251C857FC2EE89D4931F23D96646835257892FB6B42B687CCD0345947F"
			~ x"2D9CB8A1D0A64B6266D95BCAFE37FA904078BF6E7E9868DD327FCDF9B1FBC1B6"
			~ x"F323660BEAC65192B886AD31B7B2F260B5E8D8500836296F3AB756DABC8884CD"
			~ x"75FA36902580FB94DCF7101CBE733FC50800BDA8B32A4499152748167E77C576"
			~ x"856992C68CE41F582E281CCBEC0598486B706EEA91B59C0782E21D982D71BA32"
			~ x"9C6F9533F0B4468FFE75875D4CCCEAE45A5D6EECBC19C6D64B41DACADD04C58C"
			~ x"391CD15D3C8AB0967840AB55B107925F169C0E3B08F7A1F5284A2DC4915C90DB"
			~ x"B4DD47F827DBBE1781F8516AABDE6DBA499D80E2A9DFA37B371C570DD686A420"
			~ x"658E3C382E22FEDBD72AB30672011AE6598EFBFA8583CC57B1E309A2927280E1"
			~ x"246DABC87763D5789B1FB335F1E971683FD5684EA164802EFE5FD61252F71B30"
			~ x"2AB465975ED9A9A9E74B3991E0F0586C97C91D1EE53E8FE719F019A2B5BD3EAD"
			~ x"6A4A239448F1E66458353537984368BD92344032A0F129E88E80B473BF8D28A0"
			~ x"EB691A89AE8F2464CB1839087618C9EA274D5C1BC12C0C9253213B809DF2EA4B"
			~ x"459634A84F975F88690D5813C5F129625710DE15A85C1682DCA5CE3EA6165A3D"
			~ x"77178E1A23C30005906B02187BBA76F289348C1A269644DF544F9C5B02B598F9"
			~ x"E5ED0B66E8BC41F72A5567C62729355A238D3747E55BA74E1A05B778EB0BE88B"
		~ x"0203"~x"010001" // INTEGER: publicExponent (3 bytes)
		~ x"02820201"       // INTEGER: privateExponent (513 bytes = 0x00 + 512 bytes)
			~ x"00BE7B4A7C873AC2E984621664A20D79DEAD170C54A63098F539448D7D0AC5326A"
			~ x"1CBBD259D71B353D768CA73D5680D6B8CB970A335F70BD08ECC7264FB5FE0358"
			~ x"B0B6672DCECB163D96566C4B2421F259D207C8BC6130C4F1E6C86AD4EC618682"
			~ x"5D4398D07BFB61BC2C6638469673604713D1737EEA2228C47129FBCB666EABED"
			~ x"9916D770ECEAFB4EE0D443D535A269122E156F885963A8EE1D2FC528A9E8F802"
			~ x"74E859032D60C6830F223932E898FC35DF1A77EB0B4F0D61DE7CD5CFCF718522"
			~ x"1056BB7A4558E8F5C34EE4E2E2F005893382A19FDBD1A536F043EE2BCB452C94"
			~ x"FCC1263007ACBB060A3D50C76803774B8E7BC85E0DE54C8A7B377304A948961B"
			~ x"701CD9106F76CF7F01A8E7F619FA62D3FD72A1D04DFEEB7DA69826D973E998D7"
			~ x"6EABD9B504DDD36FCE96FBE82AD392A8483FCB458B182FCD415B4A07C63C2825"
			~ x"AD00617AA666F7B9C881F706CE4BD17DA348A98A092D3ED8247834E5F7FD4357"
			~ x"C87AA00A408E73D6D2BEE6C17BD3EEDC1BFB9FB6199FA1DE349321F1E970FFA5"
			~ x"EDFA1B7E5B6883B2627BE5F8F5515BB975AC0B2B355010C3A271A34724B878D4"
			~ x"0ACA570689B84B05753688F805F3A18D654606F93E24650DF139075C3D8A9A53"
			~ x"F1946ABED39B4A781D2BCBDC981AD8FA15F707C4286CF19D506CF68EA7DF1ECA"
			~ x"A01E085FBA17E28DA4A57BFB2A6CD87D951F7DEA2BE7979C983C84AC138B03A1"
		~ x"02820101"       // INTEGER: prime1 (257 bytes = 0x00 + 256 bytes)
			~ x"00FBCEC02A8F4D6FDF4524FA4ADF3B4BEC208C1DA94C5957F899A2F2FEE56B3953"
			~ x"9C78649F1EC58D5EC6FB1E3AF6E93704BD3B4068C5D845409F69F4BD99BF4D59"
			~ x"AC61D4FB264AF6B779CEEF3994790F55A5986AFE09D190F4A344A8F4957EAB94"
			~ x"75EF8169C8AC035D088B82B65B7123A760A59E051D677E7C084E928474D6CCDA"
			~ x"77178B301D027E806F0B0DBA188B9AE8C3971223FF8C80BBD01F15926A5B1AB6"
			~ x"B4A92A06AE55571A943543D4902D5B97FA8D024BD6C3DDC6739BD46C83DF3110"
			~ x"9C78F2ADF6CA4C4FEC2FDEE610DC794C47B63A3396BE8D0D535D63EA44A7E9A1"
			~ x"D053A593291C4A96BBADAD1C857040C40F94E3245EC961090EC5420B43E06319"
		~ x"02820101"       // INTEGER: prime2 (257 bytes = 0x00 + 256 bytes)
			~ x"00F2BB240DA83307F62699EE0BFCEB360C9EFEB35594F16ABE2AEF5D0C4380630D"
			~ x"EB96A4B3FB9158338384E080B35292F3715404173802097411BC5A7C5F080188"
			~ x"3F54120F315F2AA4F32BD1D14BADF4F9FA05C82D5BBF5E5B411825C4AC5B3AE9"
			~ x"A8994D36AB8327C1230066955197FB95E40AEB3849E1CD82FECF8F8DEB95E446"
			~ x"788C76953803A0F8CE14D312C5E30990C2EF4E2C1F88EF79DC656278F054E47B"
			~ x"FFC5DA897F7FF4ADDF344FD48EBFC81B1D49FEA206F4617FE982570487BA6356"
			~ x"B9EE5D20AF64FE9F9ED37B213DEEDB8ED179513F9F338CCD2F895C18948B85C1"
			~ x"E7BF9ADA85C39B6B674E31F2FE5E0A0C8207BA14067D43392FAC7699BA21E143"
		~ x"02820101"       // INTEGER: exponent1 (257 bytes = 0x00 + 256 bytes)
			~ x"00ECE7555035466B8C296762BBF24DBD5E4838CAE72ED797B66205368CAD973575"
			~ x"FE6E1E6CBDECAAD6926A4BC4B9EC2C411F2F91A7810BBA0BD46F413CE85B5D10"
			~ x"92E7F012E1B2017018FFA17E10BBDCBB7D726AA6DAE1F978CFEA96F2957B793D"
			~ x"D1BF25883AADEAF42A47E7105DF391D1B551DBDB801090A56CC34F81A2D33C24"
			~ x"058B76FE2B2CDF8B41EDAA5A7D214AFAD699590DD92D7D2835E428CD79968109"
			~ x"87EAE789259750BDC6D65E1CAC10A06DD9E1B45959932921BE3ECB99D46FB59F"
			~ x"A536FD4AC2370D98DBE325D859E0B3961A99CD24201CE263B91CD215E3C5FE3E"
			~ x"A8DB2999CC41BBC3188B8BA49BBE4290B30026BB5F1A235AFC3485B04789E271"
		~ x"02820100"       // INTEGER: exponent2 (256 bytes)
			~ x"0A8003F03F4D6DD3BD19BD8D71346F931E31A06A5C56112B06CA71F8FCD689F2"
			~ x"69358C0C691E81754104377DF9C3E1AD7C428926C3FA7A9435CC3311DC3E896A"
			~ x"6E6AE1991CA6A43E9C7251D23EF6D87913D2BA351419F427F869E6005B005B4D"
			~ x"0E490B690904546CEB69B20655904086DC65888557D4D7C209E9CAA8F5FEF6F0"
			~ x"0178FA0C3C6F13C08F91A10BD7D9996954B56B694737F23C1047A679DAD3A14A"
			~ x"A7E6D42C4C82A97FF7FED85136979F3D6507F566E6EC1D679E1F504A56E0BE39"
			~ x"5B33AF7DA178B9F707B4D847B8D923504B4977354C5ABB8588BFE566FECE064C"
			~ x"3C0D32D2AF24A60D805B86979F5F4C09FC79FF17ACAC308341C7B11DB74A8DE7"
		~ x"02820101"       // INTEGER: coefficient (257 bytes = 0x00 + 256 bytes)
			~ x"00A6F3166C99E3CED65E3789A2E41F9DE204A11CC71764EB6C8EA4B4211A1CA170"
			~ x"8D8F3609663951D242DD895EAE412396557BAD728978646C8E7969CDDDE4E40F"
			~ x"6C5AD5448F0A09E550818455253970129DA430D8D6721DA6DDABA295D51A737D"
			~ x"C18ABE939B5AFAD41F73A1B80E697343A1F508D0D33C4B6F69909F4A92B5B561"
			~ x"70A371EB1662854845E5FF97E428E8AFF61E34BAA4C374793009F8BEB36616C4"
			~ x"5A7605911B3860B6319204A6F6C18B4085E8A64EEF9D9987748FBA3E29BA1ADC"
			~ x"84E61247944EE7622588F7B84F5093C9D1127637368AC6F471844F8D6B28484C"
			~ x"277A6A9878933F8D4441D5450FA8A58C6EE261977A875B7971BB322E80A1EB5A"
		);
	auto prvKeyBin = cast(immutable(ubyte)[2308])(x""
		// INTEGER: modulus (512 bytes)
		~ x"EEC185251C857FC2EE89D4931F23D96646835257892FB6B42B687CCD0345947F"
		~ x"2D9CB8A1D0A64B6266D95BCAFE37FA904078BF6E7E9868DD327FCDF9B1FBC1B6"
		~ x"F323660BEAC65192B886AD31B7B2F260B5E8D8500836296F3AB756DABC8884CD"
		~ x"75FA36902580FB94DCF7101CBE733FC50800BDA8B32A4499152748167E77C576"
		~ x"856992C68CE41F582E281CCBEC0598486B706EEA91B59C0782E21D982D71BA32"
		~ x"9C6F9533F0B4468FFE75875D4CCCEAE45A5D6EECBC19C6D64B41DACADD04C58C"
		~ x"391CD15D3C8AB0967840AB55B107925F169C0E3B08F7A1F5284A2DC4915C90DB"
		~ x"B4DD47F827DBBE1781F8516AABDE6DBA499D80E2A9DFA37B371C570DD686A420"
		~ x"658E3C382E22FEDBD72AB30672011AE6598EFBFA8583CC57B1E309A2927280E1"
		~ x"246DABC87763D5789B1FB335F1E971683FD5684EA164802EFE5FD61252F71B30"
		~ x"2AB465975ED9A9A9E74B3991E0F0586C97C91D1EE53E8FE719F019A2B5BD3EAD"
		~ x"6A4A239448F1E66458353537984368BD92344032A0F129E88E80B473BF8D28A0"
		~ x"EB691A89AE8F2464CB1839087618C9EA274D5C1BC12C0C9253213B809DF2EA4B"
		~ x"459634A84F975F88690D5813C5F129625710DE15A85C1682DCA5CE3EA6165A3D"
		~ x"77178E1A23C30005906B02187BBA76F289348C1A269644DF544F9C5B02B598F9"
		~ x"E5ED0B66E8BC41F72A5567C62729355A238D3747E55BA74E1A05B778EB0BE88B"
		// INTEGER: publicExponent (4 bytes)
		~ x"00010001"
		// INTEGER: privateExponent (512 bytes)
		~ x"BE7B4A7C873AC2E984621664A20D79DEAD170C54A63098F539448D7D0AC5326A"
		~ x"1CBBD259D71B353D768CA73D5680D6B8CB970A335F70BD08ECC7264FB5FE0358"
		~ x"B0B6672DCECB163D96566C4B2421F259D207C8BC6130C4F1E6C86AD4EC618682"
		~ x"5D4398D07BFB61BC2C6638469673604713D1737EEA2228C47129FBCB666EABED"
		~ x"9916D770ECEAFB4EE0D443D535A269122E156F885963A8EE1D2FC528A9E8F802"
		~ x"74E859032D60C6830F223932E898FC35DF1A77EB0B4F0D61DE7CD5CFCF718522"
		~ x"1056BB7A4558E8F5C34EE4E2E2F005893382A19FDBD1A536F043EE2BCB452C94"
		~ x"FCC1263007ACBB060A3D50C76803774B8E7BC85E0DE54C8A7B377304A948961B"
		~ x"701CD9106F76CF7F01A8E7F619FA62D3FD72A1D04DFEEB7DA69826D973E998D7"
		~ x"6EABD9B504DDD36FCE96FBE82AD392A8483FCB458B182FCD415B4A07C63C2825"
		~ x"AD00617AA666F7B9C881F706CE4BD17DA348A98A092D3ED8247834E5F7FD4357"
		~ x"C87AA00A408E73D6D2BEE6C17BD3EEDC1BFB9FB6199FA1DE349321F1E970FFA5"
		~ x"EDFA1B7E5B6883B2627BE5F8F5515BB975AC0B2B355010C3A271A34724B878D4"
		~ x"0ACA570689B84B05753688F805F3A18D654606F93E24650DF139075C3D8A9A53"
		~ x"F1946ABED39B4A781D2BCBDC981AD8FA15F707C4286CF19D506CF68EA7DF1ECA"
		~ x"A01E085FBA17E28DA4A57BFB2A6CD87D951F7DEA2BE7979C983C84AC138B03A1"
		// INTEGER: prime1 (256 bytes)
		~ x"FBCEC02A8F4D6FDF4524FA4ADF3B4BEC208C1DA94C5957F899A2F2FEE56B3953"
		~ x"9C78649F1EC58D5EC6FB1E3AF6E93704BD3B4068C5D845409F69F4BD99BF4D59"
		~ x"AC61D4FB264AF6B779CEEF3994790F55A5986AFE09D190F4A344A8F4957EAB94"
		~ x"75EF8169C8AC035D088B82B65B7123A760A59E051D677E7C084E928474D6CCDA"
		~ x"77178B301D027E806F0B0DBA188B9AE8C3971223FF8C80BBD01F15926A5B1AB6"
		~ x"B4A92A06AE55571A943543D4902D5B97FA8D024BD6C3DDC6739BD46C83DF3110"
		~ x"9C78F2ADF6CA4C4FEC2FDEE610DC794C47B63A3396BE8D0D535D63EA44A7E9A1"
		~ x"D053A593291C4A96BBADAD1C857040C40F94E3245EC961090EC5420B43E06319"
		// INTEGER: prime2 (256 bytes)
		~ x"F2BB240DA83307F62699EE0BFCEB360C9EFEB35594F16ABE2AEF5D0C4380630D"
		~ x"EB96A4B3FB9158338384E080B35292F3715404173802097411BC5A7C5F080188"
		~ x"3F54120F315F2AA4F32BD1D14BADF4F9FA05C82D5BBF5E5B411825C4AC5B3AE9"
		~ x"A8994D36AB8327C1230066955197FB95E40AEB3849E1CD82FECF8F8DEB95E446"
		~ x"788C76953803A0F8CE14D312C5E30990C2EF4E2C1F88EF79DC656278F054E47B"
		~ x"FFC5DA897F7FF4ADDF344FD48EBFC81B1D49FEA206F4617FE982570487BA6356"
		~ x"B9EE5D20AF64FE9F9ED37B213DEEDB8ED179513F9F338CCD2F895C18948B85C1"
		~ x"E7BF9ADA85C39B6B674E31F2FE5E0A0C8207BA14067D43392FAC7699BA21E143"
		// INTEGER: exponent1 (256 bytes)
		~ x"ECE7555035466B8C296762BBF24DBD5E4838CAE72ED797B66205368CAD973575"
		~ x"FE6E1E6CBDECAAD6926A4BC4B9EC2C411F2F91A7810BBA0BD46F413CE85B5D10"
		~ x"92E7F012E1B2017018FFA17E10BBDCBB7D726AA6DAE1F978CFEA96F2957B793D"
		~ x"D1BF25883AADEAF42A47E7105DF391D1B551DBDB801090A56CC34F81A2D33C24"
		~ x"058B76FE2B2CDF8B41EDAA5A7D214AFAD699590DD92D7D2835E428CD79968109"
		~ x"87EAE789259750BDC6D65E1CAC10A06DD9E1B45959932921BE3ECB99D46FB59F"
		~ x"A536FD4AC2370D98DBE325D859E0B3961A99CD24201CE263B91CD215E3C5FE3E"
		~ x"A8DB2999CC41BBC3188B8BA49BBE4290B30026BB5F1A235AFC3485B04789E271"
		// INTEGER: exponent2 (256 bytes)
		~ x"0A8003F03F4D6DD3BD19BD8D71346F931E31A06A5C56112B06CA71F8FCD689F2"
		~ x"69358C0C691E81754104377DF9C3E1AD7C428926C3FA7A9435CC3311DC3E896A"
		~ x"6E6AE1991CA6A43E9C7251D23EF6D87913D2BA351419F427F869E6005B005B4D"
		~ x"0E490B690904546CEB69B20655904086DC65888557D4D7C209E9CAA8F5FEF6F0"
		~ x"0178FA0C3C6F13C08F91A10BD7D9996954B56B694737F23C1047A679DAD3A14A"
		~ x"A7E6D42C4C82A97FF7FED85136979F3D6507F566E6EC1D679E1F504A56E0BE39"
		~ x"5B33AF7DA178B9F707B4D847B8D923504B4977354C5ABB8588BFE566FECE064C"
		~ x"3C0D32D2AF24A60D805B86979F5F4C09FC79FF17ACAC308341C7B11DB74A8DE7"
		// INTEGER: coefficient (256 bytes)
		~ x"A6F3166C99E3CED65E3789A2E41F9DE204A11CC71764EB6C8EA4B4211A1CA170"
		~ x"8D8F3609663951D242DD895EAE412396557BAD728978646C8E7969CDDDE4E40F"
		~ x"6C5AD5448F0A09E550818455253970129DA430D8D6721DA6DDABA295D51A737D"
		~ x"C18ABE939B5AFAD41F73A1B80E697343A1F508D0D33C4B6F69909F4A92B5B561"
		~ x"70A371EB1662854845E5FF97E428E8AFF61E34BAA4C374793009F8BEB36616C4"
		~ x"5A7605911B3860B6319204A6F6C18B4085E8A64EEF9D9987748FBA3E29BA1ADC"
		~ x"84E61247944EE7622588F7B84F5093C9D1127637368AC6F471844F8D6B28484C"
		~ x"277A6A9878933F8D4441D5450FA8A58C6EE261977A875B7971BB322E80A1EB5A"
		);
	// openssl rsa -in private_key_rsa4096.pem -pubout -out -
	auto pubKeyPem = "-----BEGIN PUBLIC KEY-----\r\n"
		~ "MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEA7sGFJRyFf8LuidSTHyPZ\r\n"
		~ "ZkaDUleJL7a0K2h8zQNFlH8tnLih0KZLYmbZW8r+N/qQQHi/bn6YaN0yf835sfvB\r\n"
		~ "tvMjZgvqxlGSuIatMbey8mC16NhQCDYpbzq3Vtq8iITNdfo2kCWA+5Tc9xAcvnM/\r\n"
		~ "xQgAvaizKkSZFSdIFn53xXaFaZLGjOQfWC4oHMvsBZhIa3Bu6pG1nAeC4h2YLXG6\r\n"
		~ "MpxvlTPwtEaP/nWHXUzM6uRaXW7svBnG1ktB2srdBMWMORzRXTyKsJZ4QKtVsQeS\r\n"
		~ "XxacDjsI96H1KEotxJFckNu03Uf4J9u+F4H4UWqr3m26SZ2A4qnfo3s3HFcN1oak\r\n"
		~ "IGWOPDguIv7b1yqzBnIBGuZZjvv6hYPMV7HjCaKScoDhJG2ryHdj1XibH7M18elx\r\n"
		~ "aD/VaE6hZIAu/l/WElL3GzAqtGWXXtmpqedLOZHg8Fhsl8kdHuU+j+cZ8Bmitb0+\r\n"
		~ "rWpKI5RI8eZkWDU1N5hDaL2SNEAyoPEp6I6AtHO/jSig62kaia6PJGTLGDkIdhjJ\r\n"
		~ "6idNXBvBLAySUyE7gJ3y6ktFljSoT5dfiGkNWBPF8SliVxDeFahcFoLcpc4+phZa\r\n"
		~ "PXcXjhojwwAFkGsCGHu6dvKJNIwaJpZE31RPnFsCtZj55e0LZui8QfcqVWfGJyk1\r\n"
		~ "WiONN0flW6dOGgW3eOsL6IsCAwEAAQ==\r\n"
		~ "-----END PUBLIC KEY-----\r\n";
	auto pubKeyDer = cast(immutable(ubyte)[])(x"30820222"        // SEQUENCE (546 bytes)
		~ x"300d"~x"06092a864886f70d0101010500" // SEQUENCE (13 bytes) / OID rsaEncryption
		~ x"0382020f00"                 // BIT STRING (527 bytes / 0bits)
			~ x"3082020a"                   // SEQUENCE (522)
				~ x"02820201"                   // INTEGER: modulus (513 bytes)
					~ x"00eec185251c857fc2ee89d4931f23d96646835257892fb6b42b687ccd0345947f"
					~ x"2d9cb8a1d0a64b6266d95bcafe37fa904078bf6e7e9868dd327fcdf9b1fbc1b6"
					~ x"f323660beac65192b886ad31b7b2f260b5e8d8500836296f3ab756dabc8884cd"
					~ x"75fa36902580fb94dcf7101cbe733fc50800bda8b32a4499152748167e77c576"
					~ x"856992c68ce41f582e281ccbec0598486b706eea91b59c0782e21d982d71ba32"
					~ x"9c6f9533f0b4468ffe75875d4ccceae45a5d6eecbc19c6d64b41dacadd04c58c"
					~ x"391cd15d3c8ab0967840ab55b107925f169c0e3b08f7a1f5284a2dc4915c90db"
					~ x"b4dd47f827dbbe1781f8516aabde6dba499d80e2a9dfa37b371c570dd686a420"
					~ x"658e3c382e22fedbd72ab30672011ae6598efbfa8583cc57b1e309a2927280e1"
					~ x"246dabc87763d5789b1fb335f1e971683fd5684ea164802efe5fd61252f71b30"
					~ x"2ab465975ed9a9a9e74b3991e0f0586c97c91d1ee53e8fe719f019a2b5bd3ead"
					~ x"6a4a239448f1e66458353537984368bd92344032a0f129e88e80b473bf8d28a0"
					~ x"eb691a89ae8f2464cb1839087618c9ea274d5c1bc12c0c9253213b809df2ea4b"
					~ x"459634a84f975f88690d5813c5f129625710de15a85c1682dca5ce3ea6165a3d"
					~ x"77178e1a23c30005906b02187bba76f289348c1a269644df544f9c5b02b598f9"
					~ x"e5ed0b66e8bc41f72a5567c62729355a238d3747e55ba74e1a05b778eb0be88b"
				~ x"0203"~x"010001"             // INTEGER: publicExponent (3 bytes)
		);
	auto pubKeyBin = cast(immutable(ubyte)[516])(x""
		// INTEGER: modulus (512 bytes)
		~ x"eec185251c857fc2ee89d4931f23d96646835257892fb6b42b687ccd0345947f"
		~ x"2d9cb8a1d0a64b6266d95bcafe37fa904078bf6e7e9868dd327fcdf9b1fbc1b6"
		~ x"f323660beac65192b886ad31b7b2f260b5e8d8500836296f3ab756dabc8884cd"
		~ x"75fa36902580fb94dcf7101cbe733fc50800bda8b32a4499152748167e77c576"
		~ x"856992c68ce41f582e281ccbec0598486b706eea91b59c0782e21d982d71ba32"
		~ x"9c6f9533f0b4468ffe75875d4ccceae45a5d6eecbc19c6d64b41dacadd04c58c"
		~ x"391cd15d3c8ab0967840ab55b107925f169c0e3b08f7a1f5284a2dc4915c90db"
		~ x"b4dd47f827dbbe1781f8516aabde6dba499d80e2a9dfa37b371c570dd686a420"
		~ x"658e3c382e22fedbd72ab30672011ae6598efbfa8583cc57b1e309a2927280e1"
		~ x"246dabc87763d5789b1fb335f1e971683fd5684ea164802efe5fd61252f71b30"
		~ x"2ab465975ed9a9a9e74b3991e0f0586c97c91d1ee53e8fe719f019a2b5bd3ead"
		~ x"6a4a239448f1e66458353537984368bd92344032a0f129e88e80b473bf8d28a0"
		~ x"eb691a89ae8f2464cb1839087618c9ea274d5c1bc12c0c9253213b809df2ea4b"
		~ x"459634a84f975f88690d5813c5f129625710de15a85c1682dca5ce3ea6165a3d"
		~ x"77178e1a23c30005906b02187bba76f289348c1a269644df544f9c5b02b598f9"
		~ x"e5ed0b66e8bc41f72a5567c62729355a238d3747e55ba74e1a05b778eb0be88b"
		// INTEGER: publicExponent (4 bytes)
		~ x"00010001"
		);
	// openssl pkeyutl -sign -inkey private_key_rsa4096.pem -in test.txt -out -
	auto signatureExample1 = cast(immutable(ubyte)[])(x""
		~ x"8c4d1661b50749b7e54554204697d0dd99b54fe37cbbc25a012065723fb126f4"
		~ x"a94a81c5a7bf4f8e3bd63224b036857e2e1b0ffb74581b054037ce48430356fb"
		~ x"c7018314f845570cddad47040183ec8ce88a52a1b8ed3c430c7b37bfb547eb86"
		~ x"2fb52c802e7e1b4e643a55655d5ecc3f8a4dd6cbf6fde01cf1e30106d5c4942a"
		~ x"3d29201d96b96da49f7bb2b3d741fb80ba6f3dbd20304f7c76778951c1a5a08f"
		~ x"0ed1a74988664987c4f5e9b63a4e5927dbb57a09c45a0380c685aa26a25cbb1d"
		~ x"451d54d6842098eab816f2f84845d454d64218cda4a8d09b17394958cc0d0834"
		~ x"a1273af4a7ef07bb387ada53515a2c69735ec8bdf731032deb34d97490570e9f"
		~ x"7a72967fd456efd69fafc93f0d087a7be9cd62a5756023b14e0edc6aa3f9eabc"
		~ x"6e52a8a41a6b6705ecdb5ab26b1c2866b9c1a464f0c85fd8230fe9ad4bd4b7b8"
		~ x"963deda74470f0b2d7ee1c859264a5b727bf0df9374ccde04517c3905e0f6eee"
		~ x"eddd1e500ed373b2a163b4283e4d74b48743c51e70445771e793233493df7070"
		~ x"794cda111a9102acfe4aacd4dea31a8d742e4be5e21ca9809089f55f3172fffb"
		~ x"89f6356943565db8da1abded93381495fca6ddcb584fc3cca3dbd683f2e8dbbb"
		~ x"bf2cec673f9704f8d6ef53faf4565c2137b646b58918ce03894d187de56d30ee"
		~ x"68c07e3e0e9177f804595726e61d3f44d8993a192c48470d6003e894edebd500");
	// openssl dgst -sha256 -binary test.txt | openssl pkeyutl -sign -inkey private_key_rsa4096.pem -out sign_rsa.bin
	// openssl dgst -sha256 -binary test.txt | openssl pkeyutl -verify -pubin -inkey public_key_rsa4096.pem -sigfile sign_rsa.bin
	auto signaturePhSHA256Example1 = cast(immutable(ubyte)[])(x""
		~ x"BBBB37C625DD3D17BA76E657C82D8781EA5CF0C877A001FEC9C35E37B47CD82F"
		~ x"45F7AA876705FB0BCF14B5850EDC7A832AD824F1E4170F04680F2AF4691FCF41"
		~ x"FABCB9C01EBBB7DE038F203EF7E433EF01454054798262DC1B0FC04C97DE6DEE"
		~ x"E804E0A598F76FF44936F1304D5DA41D9BBB3FD1FE2E74FF841A17280476C170"
		~ x"260D76F5245D101E453BAAEA115053F2F352889067F07A8A0496C16A284E3E4D"
		~ x"1B0FC6BCF7AA88B0722D122B256EF5C95FB63EB9972134141E626A9B53F8ACC3"
		~ x"1C73DD2B1CFE358ACC0EA64C6070C8005B1B30B54185380F1D94C7EC97550DD4"
		~ x"992B52B529FF58374008F8D6F8DB7C31B0A49227EC7BDA8E78384C6346692FEA"
		~ x"A7AFE2DCE6F1EFCE20C891A38F90CC9E7C2DC0CDD18D53380101E8B2DD645E0D"
		~ x"5A4D786F7FE84AA358B3AA307258941B10F5C6A2D0E5844FE19153B5B0FAB1CD"
		~ x"8B327F3F2502D8065611F35D4CF42B2829A142B0FD21AE9F89F892537D46050C"
		~ x"D4767614FB6D4361DB71AD6597650DC806FF92BB0EA2CB6C2AA698D4E5F63D2C"
		~ x"2CF58D87494D18AC537F3152040C2526A02BFB22D67092E5F3701D8AB7C52A85"
		~ x"2A6E25D323C1FB736C57605619EF2E307F113FECFBF2741ED7C89E23DA6C7B16"
		~ x"AF64B649D9C17D6F8E2C08904E6F7353020E0F141BE8F77B59229FCA876B901B"
		~ x"71DE27C2A95C5473C18AC7BA27802A38EE129F4F7DC9D55D8095D1E8CC2CCD65");
	// openssl dgst -sha256 -sign private_key_rsa4096.pem -out - test.txt
	// openssl dgst -sha256 -verify public_key_rsa4096.pem -signature - test.txt
	auto signaturePhSHA256Example2 = cast(immutable(ubyte)[])(x""
		~ x"b3d5263a36ad17931b18a791011f604873d2e03a94414d978b0dda9f56ce1c5b"
		~ x"01a209aa783544d0ef586f64ce0afbffd05ff987ebc3fcda706a90b43a54039b"
		~ x"14a62f578dd9f7872a4479dbcc1d596033bbf27df54a2e2367f3d86fdd5b5ad5"
		~ x"421ffadfd87dbe2de9c57f1d96e80b559cc0e4c936499d1697677449be619277"
		~ x"d4018323dc1119d5283ad504cb498d39951fc9ae5a030eb99caa0ad566164c7f"
		~ x"dc0a40e0cfe01104eb66df5c2afcea4c01c6e3d5eaf5655bc6ba597763c389dc"
		~ x"55b7a9640e2ac3abc0a2500b54785856bc16d964d88aeb9da92363840bbaadb7"
		~ x"86ae60de9836697d4d07180622ef5345cb22919c6e0d2905e6aaea466c6ef185"
		~ x"19499442e1fd6178f5199b53c2fba3334867ff7af753e2256918143483150d60"
		~ x"0491a6172f99282137e589ea38f0e35a93bcf66d6db95edd588769067d95da11"
		~ x"dbd9d0da46a2cc68e54addf29a10ca5ce8b5ef40626769307a1686f069c03163"
		~ x"0732f448c08421acb7fb20b779ad1e57668541193b6f9abae1e9ba1d0a86ab66"
		~ x"8d4d0cd949cc59a6f8263d65b01a836be51989afd5118de20d458be31633194d"
		~ x"500b8117b9f2fd7f82bacffc8a821906b2f4b9a6f06212fb10fde3c15176a58e"
		~ x"d010d927dbe41336f965b7e4f5a82d0f11908834d0c3d95c95648a2e5a80a894"
		~ x"99beb6009620a34d582531ba88a9f003d020d8ebecf80cb723134e94032a5101");
	auto prvKey = OpenSSLCmdRSA4096Engine.PrivateKey.fromPEM(prvKeyPem);
	assert(prvKey.toPEM().splitLines == prvKeyPem.splitLines);
	assert(prvKey.toDER() == prvKeyDer);
	assert(prvKey.toBinary() == prvKeyBin);
	auto prvKey2 = OpenSSLCmdRSA4096Engine.PrivateKey.fromDER(prvKeyDer);
	assert(prvKey2.toPEM().splitLines == prvKeyPem.splitLines);
	assert(prvKey2.toDER() == prvKeyDer);
	assert(prvKey2.toBinary() == prvKeyBin);
	auto prvKey3 = OpenSSLCmdRSA4096Engine.PrivateKey.fromBinary(prvKeyBin);
	assert(prvKey3.toPEM().splitLines == prvKeyPem.splitLines);
	assert(prvKey3.toDER() == prvKeyDer);
	assert(prvKey3.toBinary() == prvKeyBin);
	
	auto pubKey = OpenSSLCmdRSA4096Engine.PublicKey.fromPEM(pubKeyPem);
	assert(pubKey.toPEM().splitLines == pubKeyPem.splitLines);
	assert(pubKey.toDER() == pubKeyDer);
	assert(pubKey.toBinary() == pubKeyBin);
	auto pubKey2 = OpenSSLCmdRSA4096Engine.PublicKey.fromDER(pubKeyDer);
	assert(pubKey2.toPEM().splitLines == pubKeyPem.splitLines);
	assert(pubKey2.toDER() == pubKeyDer);
	assert(pubKey2.toBinary() == pubKeyBin);
	auto pubKey3 = OpenSSLCmdRSA4096Engine.PublicKey.fromBinary(pubKeyBin);
	assert(pubKey3.toPEM().splitLines == pubKeyPem.splitLines);
	assert(pubKey3.toDER() == pubKeyDer);
	assert(pubKey3.toBinary() == pubKeyBin);
	auto pubKey4 = OpenSSLCmdRSA4096Engine.PublicKey.createKey(prvKey);
	assert(pubKey4.toPEM().splitLines == pubKeyPem.splitLines);
	assert(pubKey4.toDER() == pubKeyDer);
	assert(pubKey4.toBinary() == pubKeyBin);
	
	auto signer = Signer!OpenSSLCmdRSA4096Engine(prvKey.toBinary);
	auto message = "Hello, World!";
	signer.update(message.representation);
	auto signature = signer.sign();
	assert(signature[] == signatureExample1[]);
	
	auto verifier = Verifier!OpenSSLCmdRSA4096Engine(pubKey.toBinary);
	verifier.update(message.representation);
	assert(verifier.verify(signature));
	assert(verifier.verify(signatureExample1));
	//assert(verifier.verify(signatureExample2));
	
	auto signer2 = Signer!(OpenSSLCmdRSA4096Engine, SHA256)(prvKey.toBinary);
	signer2.update(message.representation);
	auto signature2 = signer2.sign();
	assert(signature2[] == signaturePhSHA256Example1[]);
	
	auto verifier2 = Verifier!(OpenSSLCmdRSA4096Engine, SHA256)(pubKey.toBinary);
	verifier2.update(message.representation);
	assert(verifier2.verify(signature2));
	assert(verifier2.verify(signaturePhSHA256Example1));
	//assert(verifier2.verify(signaturePhSHA256Example2));
	
	auto encrypter = Encrypter!OpenSSLCmdRSA4096Engine(pubKey.toPEM);
	auto encrypted = encrypter.encrypt(message.representation);
	
	auto decrypter = Decrypter!OpenSSLCmdRSA4096Engine(prvKey.toPEM);
	auto decrypted = decrypter.decrypt(encrypted);
	assert(decrypted == message.representation);
}


/*******************************************************************************
 * Key exchange
 */
struct KeyExchanger(Engine)
{
private:
	Engine            _engine;
	Engine.PrivateKey _prvKey;
	immutable(ubyte)[] _derive(in Engine.PublicKey pubKey)
	{
		return _engine.derive(_prvKey, pubKey);
	}
	auto _deriveEncrypter(DigestEngine = SHA256)(in Engine.PublicKey pubKey,
		immutable(ubyte)[] salt = null, size_t aesKeyBits = 256)
	{
		auto secret = _derive(pubKey);
		auto key = secret.calcHKDF(aesKeyBits/8, salt, "aes_key");
		auto iv  = secret.calcHKDF(16, salt, "aes_iv");
		static if (isOpenSSLEngine!Engine)
			return Encrypter!OpenSSLAES256EncryptEngine(iv, key);
		else static if (isBcryptEngine!Engine)
			return Encrypter!BcryptAES256EncryptEngine(iv, key);
		else static if (isOpenSSLCmdEngine!Engine)
			return Encrypter!OpenSSLCmdAES256EncryptEngine(iv, key, _engine._cmd);
		else static assert(0, "Unsupported Engine.");
	}
	auto _deriveDecrypter(DigestEngine = SHA256)(in Engine.PublicKey pubKey,
		immutable(ubyte)[] salt = null, size_t aesKeyBits = 256)
	{
		auto secret = _derive(pubKey);
		auto key = secret.calcHKDF(aesKeyBits/8, salt, "aes_key");
		auto iv  = secret.calcHKDF(16, salt, "aes_iv");
		static if (isOpenSSLEngine!Engine)
			return Decrypter!OpenSSLAES256DecryptEngine(iv, key);
		else static if (isBcryptEngine!Engine)
			return Decrypter!BcryptAES256DecryptEngine(iv, key);
		else static if (isOpenSSLCmdEngine!Engine)
			return Decrypter!OpenSSLCmdAES256DecryptEngine(iv, key, _engine._cmd);
		else static assert(0, "Unsupported Engine.");
	}
public:
	/***************************************************************************
	 * Constructor
	 */
	this(Engine engine, Engine.PrivateKey prvKey)
	{
		_engine = engine.move();
		_prvKey = prvKey.move();
	}
	/// ditto
	static if (isOpenSSLCmdEngine!Engine)
	this(in char[] prvKeyPEM, string cmd = defaultOpenSSLCommand)
	{
		this(Engine(cmd), Engine.PrivateKey.fromPEM(prvKeyPEM));
	}
	/// ditto
	static if (isOpenSSLCmdEngine!Engine)
	this(in ubyte[] prvKeyDER, string cmd = defaultOpenSSLCommand)
	{
		this(Engine(cmd), Engine.PrivateKey.fromDER(prvKeyDER));
	}
	/// ditto
	static if (isOpenSSLCmdEngine!Engine)
	this(size_t N)(ubyte[N] prvKeyRaw, string cmd = defaultOpenSSLCommand)
	{
		this(Engine(cmd), Engine.PrivateKey.fromBinary(prvKeyRaw));
	}
	/// ditto
	static if (isOpenSSLEngine!Engine || isBcryptEngine!Engine)
	this(in char[] prvKeyPEM)
	{
		this(Engine(), Engine.PrivateKey.fromPEM(prvKeyPEM));
	}
	/// ditto
	static if (isOpenSSLEngine!Engine || isBcryptEngine!Engine)
	this(in ubyte[] prvKeyDER)
	{
		this(Engine(), Engine.PrivateKey.fromDER(prvKeyDER));
	}
	/// ditto
	static if (isOpenSSLEngine!Engine || isBcryptEngine!Engine)
	this(size_t N)(ubyte[N] prvKeyRaw)
	{
		this(Engine(), Engine.PrivateKey.fromBinary(prvKeyRaw));
	}
	
	/***************************************************************************
	 * Derive
	 */
	immutable(ubyte)[] derive(in char[] pubKeyPEM)
	{
		return _derive(Engine.PublicKey.fromPEM(pubKeyPEM));
	}
	/// ditto
	immutable(ubyte)[] derive(in ubyte[] pubKeyPEM)
	{
		return _derive(Engine.PublicKey.fromDER(pubKeyPEM));
	}
	/// ditto
	immutable(ubyte)[] derive(size_t N)(in ubyte[N] pubKeyRaw)
	{
		return _derive(Engine.PublicKey.fromBinary(pubKeyRaw));
	}
	
	/***************************************************************************
	 * Derive with calculate HKDF
	 */
	immutable(ubyte)[] deriveHKDF(DigestEngine = SHA256)(in char[] pubKeyPEM, size_t len,
		immutable(ubyte)[] salt = null, string info = null)
	{
		return _derive(Engine.PublicKey.fromPEM(pubKeyPEM)).calcHKDF(len, salt, info);
	}
	/// ditto
	immutable(ubyte)[] deriveHKDF(DigestEngine = SHA256)(in ubyte[] pubKeyDER, size_t len,
		immutable(ubyte)[] salt = null, string info = null)
	{
		return _derive(Engine.PublicKey.fromDER(pubKeyDER)).calcHKDF(len, salt, info);
	}
	/// ditto
	immutable(ubyte)[] deriveHKDF(DigestEngine = SHA256, size_t N)(in ubyte[N] pubKeyRaw, size_t len,
		immutable(ubyte)[] salt = null, string info = null)
	{
		return _derive(Engine.PublicKey.fromBinary(pubKeyRaw)).calcHKDF(len, salt, info);
	}
	
	/***************************************************************************
	 * Derive encrypter
	 */
	auto deriveEncrypter(DigestEngine = SHA256)(in char[] pubKeyPEM,
		immutable(ubyte)[] salt = null, size_t aesKeyBits = 256)
	{
		return _deriveEncrypter!DigestEngine(Engine.PublicKey.fromPEM(pubKeyPEM), salt, aesKeyBits);
	}
	/// ditto
	auto deriveEncrypter(DigestEngine = SHA256)(in ubyte[] pubKeyDER,
		immutable(ubyte)[] salt = null, size_t aesKeyBits = 256)
	{
		return _deriveEncrypter!DigestEngine(Engine.PublicKey.fromPEM(pubKeyDER));
	}
	/// ditto
	auto deriveEncrypter(DigestEngine = SHA256, size_t N)(in ubyte[N] pubKeyRaw,
		immutable(ubyte)[] salt = null, size_t aesKeyBits = 256)
	{
		return _deriveEncrypter!DigestEngine(Engine.PublicKey.fromBinary(pubKeyRaw), salt, aesKeyBits);
	}
	
	/***************************************************************************
	 * Derive decrypter
	 */
	auto deriveEncrypter(DigestEngine = SHA256)(in char[] pubKeyPEM,
		immutable(ubyte)[] salt = null, size_t aesKeyBits = 256)
	{
		return _deriveDecrypter!DigestEngine(Engine.PublicKey.fromPEM(pubKeyPEM), salt, aesKeyBits);
	}
	/// ditto
	auto deriveEncrypter(DigestEngine = SHA256)(in ubyte[] pubKeyDER,
		immutable(ubyte)[] salt = null, size_t aesKeyBits = 256)
	{
		return _deriveDecrypter!DigestEngine(Engine.PublicKey.fromPEM(pubKeyDER));
	}
	/// ditto
	auto deriveEncrypter(DigestEngine = SHA256, size_t N)(in ubyte[N] pubKeyRaw,
		immutable(ubyte)[] salt = null, size_t aesKeyBits = 256)
	{
		return _deriveDecrypter!DigestEngine(Engine.PublicKey.fromBinary(pubKeyRaw), salt, aesKeyBits);
	}
}

// ECDH KeyExchange for OpenSSL Command line
static if (enableOpenSSLCmdEngines) @system unittest
{
	if (!isCommandExisting(defaultOpenSSLCommand))
		return;
	// openssl ecparam -name prime256v1 -genkey -noout -out -
	enum prvKeyPemA = "-----BEGIN EC PRIVATE KEY-----\r\n"
		~ "MHcCAQEEIJeHOjc4tq25YVR/sNVprqEgQhlBJOl3eedH07n+j/ZuoAoGCCqGSM49\r\n"
		~ "AwEHoUQDQgAEUYxhtCt0eR238rrUBEKJjRmmUDJe8QIM4nwHv9k0WRB8L1fxTjXi\r\n"
		~ "knrRB/iPtjLJVaqw8KNn4d1D+Vo0BthyTQ==\r\n"
		~ "-----END EC PRIVATE KEY-----\r\n";
	enum prvKeyDerA = pem2der(prvKeyPemA);
	enum prvKeyBinA = x"97873a3738b6adb961547fb0d569aea12042194124e97779e747d3b9fe8ff66e".bin;
	// openssl ec -in private_key_ecdh.pem -pubout -out - 2>/dev/null
	enum pubKeyPemA = "-----BEGIN PUBLIC KEY-----\r\n"
		~ "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEUYxhtCt0eR238rrUBEKJjRmmUDJe\r\n"
		~ "8QIM4nwHv9k0WRB8L1fxTjXiknrRB/iPtjLJVaqw8KNn4d1D+Vo0BthyTQ==\r\n"
		~ "-----END PUBLIC KEY-----\r\n";
	enum pubKeyDerA = pem2der(pubKeyPemA);
	enum pubKeyBinA = x"04518c61b42b74791db7f2bad40442898d19a650325ef1020ce27c07bfd93459".bin
		~ x"107c2f57f14e35e2927ad107f88fb632c955aab0f0a367e1dd43f95a3406d8724d".bin;
	enum prvKeyPemB = "-----BEGIN EC PRIVATE KEY-----\r\n"
		~ "MHcCAQEEIEei8/Akmtw5dzC2HNOyC9/THv/j0Ki4ydOkvdwghXu1oAoGCCqGSM49\r\n"
		~ "AwEHoUQDQgAEZ+Nkd2Yg1QIkmvJuN/FU2pxerpPWk0F7Lqhpm0w1i88aq2obyDYG\r\n"
		~ "RIm2uwltkUhVYGOe/4l60FBEevzDcdUulg==\r\n"
		~ "-----END EC PRIVATE KEY-----\r\n";
	enum prvKeyDerB = pem2der(prvKeyPemB);
	enum prvKeyBinB = x"47a2f3f0249adc397730b61cd3b20bdfd31effe3d0a8b8c9d3a4bddc20857bb5".bin;
	enum pubKeyPemB = "-----BEGIN PUBLIC KEY-----\r\n"
		~ "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEZ+Nkd2Yg1QIkmvJuN/FU2pxerpPW\r\n"
		~ "k0F7Lqhpm0w1i88aq2obyDYGRIm2uwltkUhVYGOe/4l60FBEevzDcdUulg==\r\n"
		~ "-----END PUBLIC KEY-----\r\n";
	enum pubKeyDerB = pem2der(pubKeyPemB);
	enum pubKeyBinB = x"0467e364776620d502249af26e37f154da9c5eae93d693417b2ea8699b4c358b".bin
		~ x"cf1aab6a1bc836064489b6bb096d91485560639eff897ad050447afcc371d52e96".bin;
	enum sharedSecretExample = x"b95f0c31cf53c81ffbefdd32a220928868e019b3184c2fa97dac1ef9b0f530ad".bin;
	
	alias Engine = OpenSSLCmdECDHP256Engine;
	
	auto prvKeyA = Engine.PrivateKey.fromPEM(prvKeyPemA);
	auto pubKeyA = Engine.PublicKey.fromPEM(pubKeyPemA);
	auto prvKeyB = Engine.PrivateKey.fromPEM(prvKeyPemB);
	auto pubKeyB = Engine.PublicKey.fromPEM(pubKeyPemB);
	auto kxA = KeyExchanger!Engine(prvKeyA.toPEM);
	auto ssValueA = kxA.derive(pubKeyB.toPEM);
	assert(ssValueA == sharedSecretExample);
	auto kxB = KeyExchanger!Engine(prvKeyB.toPEM);
	auto ssValueB = kxB.derive(pubKeyA.toPEM);
	assert(ssValueB == sharedSecretExample);
}
// ECDH KeyExchange for OpenSSL
static if (enableOpenSSLEngines) @system unittest
{
	// openssl ecparam -name prime256v1 -genkey -noout -out -
	enum prvKeyPemA = "-----BEGIN EC PRIVATE KEY-----\r\n"
		~ "MHcCAQEEIJeHOjc4tq25YVR/sNVprqEgQhlBJOl3eedH07n+j/ZuoAoGCCqGSM49\r\n"
		~ "AwEHoUQDQgAEUYxhtCt0eR238rrUBEKJjRmmUDJe8QIM4nwHv9k0WRB8L1fxTjXi\r\n"
		~ "knrRB/iPtjLJVaqw8KNn4d1D+Vo0BthyTQ==\r\n"
		~ "-----END EC PRIVATE KEY-----\r\n";
	enum prvKeyDerA = pem2der(prvKeyPemA);
	enum prvKeyBinA = x"97873a3738b6adb961547fb0d569aea12042194124e97779e747d3b9fe8ff66e".bin;
	// openssl ec -in private_key_ecdh.pem -pubout -out - 2>/dev/null
	enum pubKeyPemA = "-----BEGIN PUBLIC KEY-----\r\n"
		~ "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEUYxhtCt0eR238rrUBEKJjRmmUDJe\r\n"
		~ "8QIM4nwHv9k0WRB8L1fxTjXiknrRB/iPtjLJVaqw8KNn4d1D+Vo0BthyTQ==\r\n"
		~ "-----END PUBLIC KEY-----\r\n";
	enum pubKeyDerA = pem2der(pubKeyPemA);
	enum pubKeyBinA = x"04518c61b42b74791db7f2bad40442898d19a650325ef1020ce27c07bfd93459".bin
		~ x"107c2f57f14e35e2927ad107f88fb632c955aab0f0a367e1dd43f95a3406d8724d".bin;
	enum prvKeyPemB = "-----BEGIN EC PRIVATE KEY-----\r\n"
		~ "MHcCAQEEIEei8/Akmtw5dzC2HNOyC9/THv/j0Ki4ydOkvdwghXu1oAoGCCqGSM49\r\n"
		~ "AwEHoUQDQgAEZ+Nkd2Yg1QIkmvJuN/FU2pxerpPWk0F7Lqhpm0w1i88aq2obyDYG\r\n"
		~ "RIm2uwltkUhVYGOe/4l60FBEevzDcdUulg==\r\n"
		~ "-----END EC PRIVATE KEY-----\r\n";
	enum prvKeyDerB = pem2der(prvKeyPemB);
	enum prvKeyBinB = x"47a2f3f0249adc397730b61cd3b20bdfd31effe3d0a8b8c9d3a4bddc20857bb5".bin;
	enum pubKeyPemB = "-----BEGIN PUBLIC KEY-----\r\n"
		~ "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEZ+Nkd2Yg1QIkmvJuN/FU2pxerpPW\r\n"
		~ "k0F7Lqhpm0w1i88aq2obyDYGRIm2uwltkUhVYGOe/4l60FBEevzDcdUulg==\r\n"
		~ "-----END PUBLIC KEY-----\r\n";
	enum pubKeyDerB = pem2der(pubKeyPemB);
	enum pubKeyBinB = x"0467e364776620d502249af26e37f154da9c5eae93d693417b2ea8699b4c358b".bin
		~ x"cf1aab6a1bc836064489b6bb096d91485560639eff897ad050447afcc371d52e96".bin;
	enum sharedSecretExample = x"b95f0c31cf53c81ffbefdd32a220928868e019b3184c2fa97dac1ef9b0f530ad".bin;
	
	alias Engine = OpenSSLECDHP256Engine;
	
	auto prvKeyA = Engine.PrivateKey.fromPEM(prvKeyPemA);
	auto pubKeyA = Engine.PublicKey.fromPEM(pubKeyPemA);
	auto prvKeyB = Engine.PrivateKey.fromPEM(prvKeyPemB);
	auto pubKeyB = Engine.PublicKey.fromPEM(pubKeyPemB);
	auto kxA = KeyExchanger!Engine(prvKeyA.toPEM);
	auto ssValueA = kxA.derive(pubKeyB.toPEM);
	assert(ssValueA == sharedSecretExample);
	auto kxB = KeyExchanger!Engine(prvKeyB.toPEM);
	auto ssValueB = kxB.derive(pubKeyA.toPEM);
	assert(ssValueB == sharedSecretExample);
}
// ECDH KeyExchange for Windows
static if (enableBcryptEngines) @system unittest
{
	import std.string;
	// openssl ecparam -name prime256v1 -genkey -noout -out -
	enum prvKeyPemA = "-----BEGIN EC PRIVATE KEY-----\r\n"
		~ "MHcCAQEEIJeHOjc4tq25YVR/sNVprqEgQhlBJOl3eedH07n+j/ZuoAoGCCqGSM49\r\n"
		~ "AwEHoUQDQgAEUYxhtCt0eR238rrUBEKJjRmmUDJe8QIM4nwHv9k0WRB8L1fxTjXi\r\n"
		~ "knrRB/iPtjLJVaqw8KNn4d1D+Vo0BthyTQ==\r\n"
		~ "-----END EC PRIVATE KEY-----\r\n";
	enum prvKeyDerA = pem2der(prvKeyPemA);
	enum prvKeyBinA = staticArray!32(x"97873a3738b6adb961547fb0d569aea12042194124e97779e747d3b9fe8ff66e".bin);
	// openssl ec -in private_key_ecdh.pem -pubout -out - 2>/dev/null
	enum pubKeyPemA = "-----BEGIN PUBLIC KEY-----\r\n"
		~ "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEUYxhtCt0eR238rrUBEKJjRmmUDJe\r\n"
		~ "8QIM4nwHv9k0WRB8L1fxTjXiknrRB/iPtjLJVaqw8KNn4d1D+Vo0BthyTQ==\r\n"
		~ "-----END PUBLIC KEY-----\r\n";
	enum pubKeyDerA = pem2der(pubKeyPemA);
	enum pubKeyBinA = staticArray!65(x"04518c61b42b74791db7f2bad40442898d19a650325ef1020ce27c07bfd93459".bin
		~ x"107c2f57f14e35e2927ad107f88fb632c955aab0f0a367e1dd43f95a3406d8724d".bin);
	enum prvKeyPemB = "-----BEGIN EC PRIVATE KEY-----\r\n"
		~ "MHcCAQEEIEei8/Akmtw5dzC2HNOyC9/THv/j0Ki4ydOkvdwghXu1oAoGCCqGSM49\r\n"
		~ "AwEHoUQDQgAEZ+Nkd2Yg1QIkmvJuN/FU2pxerpPWk0F7Lqhpm0w1i88aq2obyDYG\r\n"
		~ "RIm2uwltkUhVYGOe/4l60FBEevzDcdUulg==\r\n"
		~ "-----END EC PRIVATE KEY-----\r\n";
	enum prvKeyDerB = pem2der(prvKeyPemB);
	enum prvKeyBinB = staticArray!32(x"47a2f3f0249adc397730b61cd3b20bdfd31effe3d0a8b8c9d3a4bddc20857bb5".bin);
	enum pubKeyPemB = "-----BEGIN PUBLIC KEY-----\r\n"
		~ "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEZ+Nkd2Yg1QIkmvJuN/FU2pxerpPW\r\n"
		~ "k0F7Lqhpm0w1i88aq2obyDYGRIm2uwltkUhVYGOe/4l60FBEevzDcdUulg==\r\n"
		~ "-----END PUBLIC KEY-----\r\n";
	enum pubKeyDerB = pem2der(pubKeyPemB);
	enum pubKeyBinB = staticArray!65(x"0467e364776620d502249af26e37f154da9c5eae93d693417b2ea8699b4c358b".bin
		~ x"cf1aab6a1bc836064489b6bb096d91485560639eff897ad050447afcc371d52e96".bin);
	enum sharedSecretExample = x"b95f0c31cf53c81ffbefdd32a220928868e019b3184c2fa97dac1ef9b0f530ad".bin;
	
	alias Engine = BcryptECDHP256Engine;
	
	// 自分で生成して各種検証
	auto prvKeyA = Engine.PrivateKey.createKey();
	auto pubKeyA = Engine.PublicKey.createKey(prvKeyA);
	auto prvKeyB = Engine.PrivateKey.createKey();
	auto pubKeyB = Engine.PublicKey.createKey(prvKeyB);
	auto kexA = KeyExchanger!Engine(prvKeyA.toPEM);
	auto kexB = KeyExchanger!Engine(prvKeyB.toPEM);
	assert(kexA.derive(pubKeyB.toPEM) == kexB.derive(pubKeyA.toPEM));
	
	// 事前準備したデータでの検証
	auto prvKey1 = Engine.PrivateKey.fromPEM(prvKeyPemA);
	assert(prvKey1.toPEM().splitLines == prvKeyPemA.splitLines);
	assert(prvKey1.toDER() == prvKeyDerA);
	assert(prvKey1.toBinary() == prvKeyBinA);
	auto prvKey2 = Engine.PrivateKey.fromDER(prvKeyDerA);
	assert(prvKey2.toPEM().splitLines == prvKeyPemA.splitLines);
	assert(prvKey2.toDER() == prvKeyDerA);
	assert(prvKey2.toBinary() == prvKeyBinA);
	auto prvKey3 = Engine.PrivateKey.fromBinary(prvKeyBinA);
	assert(prvKey3.toPEM().splitLines == prvKeyPemA.splitLines);
	assert(prvKey3.toDER() == prvKeyDerA);
	assert(prvKey3.toBinary() == prvKeyBinA);
	
	auto pubKey1 = Engine.PublicKey.fromPEM(pubKeyPemA);
	assert(pubKey1.toPEM().splitLines == pubKeyPemA.splitLines);
	assert(pubKey1.toDER() == pubKeyDerA);
	assert(pubKey1.toBinary() == pubKeyBinA);
	auto pubKey2 = Engine.PublicKey.fromDER(pubKeyDerA);
	assert(pubKey2.toPEM().splitLines == pubKeyPemA.splitLines);
	assert(pubKey2.toDER() == pubKeyDerA);
	assert(pubKey2.toBinary() == pubKeyBinA);
	auto pubKey3 = Engine.PublicKey.fromBinary(pubKeyBinA);
	assert(pubKey3.toPEM().splitLines == pubKeyPemA.splitLines);
	assert(pubKey3.toDER() == pubKeyDerA);
	assert(pubKey3.toBinary() == pubKeyBinA);
	auto pubKey4 = Engine.PublicKey.createKey(prvKey1);
	assert(pubKey4.toPEM().splitLines == pubKeyPemA.splitLines);
	assert(pubKey4.toDER() == pubKeyDerA);
	assert(pubKey4.toBinary() == pubKeyBinA);
	
	auto kxA = KeyExchanger!Engine(prvKeyPemA);
	auto ssValueA = kxA.derive(pubKeyPemB);
	assert(ssValueA == sharedSecretExample);
	auto kxB = KeyExchanger!Engine(prvKeyPemB);
	auto ssValueB = kxB.derive(pubKeyPemA);
	assert(ssValueB == sharedSecretExample);
}

/*******************************************************************************
 * Create key
 */
BinaryKey!(Engine.prvKeyLen) createPrivateKey(Engine)() @trusted
{
	return Engine.PrivateKey.createKey().toBinary();
}
/// ditto
BinaryKey!(Engine.pubKeyLen) createPublicKey(Engine)(in BinaryKey!(Engine.prvKeyLen) prvKey) @trusted
{
	return Engine.PublicKey.createKey(Engine.PrivateKey.fromBinary(prvKey)).toBinary();
}
/// ditto
BinaryKey!32 createEd25519PrivateKey() @safe
{
	return createPrivateKey!DefaultEd25519Engine();
}
/// ditto
BinaryKey!32 createEd25519PublicKey(BinaryKey!32 prvKey) @safe
{
	return createPublicKey!DefaultEd25519Engine(prvKey);
}
/// ditto
BinaryKey!32 createECDSAP256PrivateKey() @safe
{
	return createPrivateKey!DefaultECDSAP256Engine();
}
/// ditto
BinaryKey!65 createECDSAP256PublicKey(BinaryKey!32 prvKey) @safe
{
	return createPublicKey!DefaultECDSAP256Engine(prvKey);
}
/// ditto
BinaryKey!32 createECDSAP256KPrivateKey() @safe
{
	return createPrivateKey!DefaultECDSAP256KEngine();
}
/// ditto
BinaryKey!65 createECDSAP256KPublicKey(BinaryKey!32 prvKey) @safe
{
	return createPublicKey!DefaultECDSAP256KEngine(prvKey);
}
/// ditto
BinaryKey!48 createECDSAP384PrivateKey() @safe
{
	return createPrivateKey!DefaultECDSAP384Engine();
}
/// ditto
BinaryKey!97 createECDSAP384PublicKey(BinaryKey!48 prvKey) @safe
{
	return createPublicKey!DefaultECDSAP384Engine(prvKey);
}
/// ditto
BinaryKey!66 createECDSAP521PrivateKey() @safe
{
	return createPrivateKey!DefaultECDSAP521Engine();
}
/// ditto
BinaryKey!133 createECDSAP521PublicKey(BinaryKey!66 prvKey) @safe
{
	return createPublicKey!DefaultECDSAP521Engine(prvKey);
}
/// ditto
ubyte[DefaultRSA4096Engine.prvKeyLen] createRSA4096PrivateKey() @safe
{
	return createPrivateKey!DefaultRSA4096Engine();
}
/// ditto
ubyte[DefaultRSA4096Engine.pubKeyLen] createRSA4096PublicKey(
	ubyte[DefaultRSA4096Engine.prvKeyLen] prvKey) @safe
{
	return createPublicKey!DefaultRSA4096Engine(prvKey);
}

@safe unittest
{
	enum msg = "test".representation;
	bool signVerifyTest(Engine, size_t N1, size_t N2)(ubyte[N1] prvKey, ubyte[N2] pubKey) @trusted
	{
		return Verifier!Engine(pubKey).verify(Signer!Engine(prvKey).sign(msg), msg);
	}
	
	if (!isOpenSSLCmdEngine!DefaultEd25519Engine
		|| (isCommandExisting(defaultOpenSSLCommand)
			&& getOpenSSLCmdVerseion(defaultOpenSSLCommand) >= SemVer(3, 0, 1)))
	{
		auto prvKeyEd25519 = createEd25519PrivateKey();
		auto pubKeyEd25519 = createEd25519PublicKey(prvKeyEd25519);
		assert(signVerifyTest!DefaultEd25519Engine(prvKeyEd25519, pubKeyEd25519));
	}
	
	auto prvKeyECDSAP256 = createECDSAP256PrivateKey();
	auto pubKeyECDSAP256 = createECDSAP256PublicKey(prvKeyECDSAP256);
	assert(signVerifyTest!DefaultECDSAP256Engine(prvKeyECDSAP256, pubKeyECDSAP256));
	
	auto prvKeyECDSAP256K = createECDSAP256KPrivateKey();
	auto pubKeyECDSAP256K = createECDSAP256KPublicKey(prvKeyECDSAP256K);
	assert(signVerifyTest!DefaultECDSAP256KEngine(prvKeyECDSAP256K, pubKeyECDSAP256K));
	
	auto prvKeyECDSAP384 = createECDSAP384PrivateKey();
	auto pubKeyECDSAP384 = createECDSAP384PublicKey(prvKeyECDSAP384);
	assert(signVerifyTest!DefaultECDSAP384Engine(prvKeyECDSAP384, pubKeyECDSAP384));
	
	auto prvKeyECDSAP521 = createECDSAP521PrivateKey();
	auto pubKeyECDSAP521 = createECDSAP521PublicKey(prvKeyECDSAP521);
	assert(signVerifyTest!DefaultECDSAP521Engine(prvKeyECDSAP521, pubKeyECDSAP521));
	
	auto prvKeyRSA4096 = createRSA4096PrivateKey();
	auto pubKeyRSA4096 = createRSA4096PublicKey(prvKeyRSA4096);
	assert(signVerifyTest!DefaultRSA4096Engine(prvKeyRSA4096, pubKeyRSA4096));
}

/*******************************************************************************
 * Conversion of key formats
 */
PEMString convPrivateKeyToPEM(Engine)(in BinaryKey!(Engine.prvKeyLen) prvKey) @trusted
{
	return Engine.PrivateKey.fromBinary(prvKey).toPEM();
}
/// ditto
BinaryKey!(Engine.prvKeyLen) convPrivateKeyFromPEM(Engine)(in char[] pem) @trusted
{
	return Engine.PrivateKey.fromPEM(pem).toBinary();
}
/// ditto
DERBinary convPrivateKeyToDER(Engine)(in BinaryKey!(Engine.prvKeyLen) prvKey) @trusted
{
	return Engine.PrivateKey.fromBinary(prvKey).toDER();
}
/// ditto
BinaryKey!(Engine.prvKeyLen) convPrivateKeyFromDER(Engine)(in ubyte[] der) @trusted
{
	return Engine.PrivateKey.fromDER(der).toBinary();
}

/// ditto
PEMString convPublicKeyToPEM(Engine)(in BinaryKey!(Engine.pubKeyLen) pubKey) @trusted
{
	return Engine.PublicKey.fromBinary(pubKey).toPEM();
}
/// ditto
BinaryKey!(Engine.pubKeyLen) convPublicKeyFromPEM(Engine)(in char[] pem) @trusted
{
	return Engine.PublicKey.fromPEM(pem).toBinary();
}
/// ditto
DERBinary convPublicKeyToDER(Engine)(in BinaryKey!(Engine.pubKeyLen) pubKey) @trusted
{
	return Engine.PublicKey.fromBinary(pubKey).toDER();
}
/// ditto
BinaryKey!(Engine.pubKeyLen) convPublicKeyFromDER(Engine)(in ubyte[] der) @trusted
{
	return Engine.PublicKey.fromDER(der).toBinary();
}


/// ditto
PEMString convEd25519PrivateKeyToPEM(in BinaryKey!32 prvKey) @safe
{
	return convPrivateKeyToPEM!DefaultEd25519Engine(prvKey);
}
/// ditto
BinaryKey!32 convEd25519PrivateKeyFromPEM(in char[] pem) @safe
{
	return convPrivateKeyFromPEM!DefaultEd25519Engine(pem);
}
/// ditto
DERBinary convEd25519PrivateKeyToDER(in BinaryKey!32 prvKey) @safe
{
	return convPrivateKeyToDER!DefaultEd25519Engine(prvKey);
}
/// ditto
BinaryKey!32 convEd25519PrivateKeyFromDER(in ubyte[] der) @safe
{
	return convPrivateKeyFromDER!DefaultEd25519Engine(der);
}

/// ditto
PEMString convEd25519PublicKeyToPEM(in BinaryKey!32 pubKey) @safe
{
	return convPublicKeyToPEM!DefaultEd25519Engine(pubKey);
}
/// ditto
BinaryKey!32 convEd25519PublicKeyFromPEM(in char[] pem) @safe
{
	return convPublicKeyFromPEM!DefaultEd25519Engine(pem);
}
/// ditto
DERBinary convEd25519PublicKeyToDER(in BinaryKey!32 pubKey) @safe
{
	return convPublicKeyToDER!DefaultEd25519Engine(pubKey);
}
/// ditto
BinaryKey!32 convEd25519PublicKeyFromDER(in ubyte[] der) @safe
{
	return convPublicKeyFromDER!DefaultEd25519Engine(der);
}


/// ditto
PEMString convECDSAP256PrivateKeyToPEM(in BinaryKey!32 prvKey) @safe
{
	return convPrivateKeyToPEM!DefaultECDSAP256Engine(prvKey);
}
/// ditto
BinaryKey!32 convECDSAP256PrivateKeyFromPEM(in char[] pem) @safe
{
	return convPrivateKeyFromPEM!DefaultECDSAP256Engine(pem);
}
/// ditto
DERBinary convECDSAP256PrivateKeyToDER(in BinaryKey!32 prvKey) @safe
{
	return convPrivateKeyToDER!DefaultECDSAP256Engine(prvKey);
}
/// ditto
BinaryKey!32 convECDSAP256PrivateKeyFromDER(in ubyte[] der) @safe
{
	return convPrivateKeyFromDER!DefaultECDSAP256Engine(der);
}

/// ditto
PEMString convECDSAP256PublicKeyToPEM(in BinaryKey!65 pubKey) @safe
{
	return convPublicKeyToPEM!DefaultECDSAP256Engine(pubKey);
}
/// ditto
BinaryKey!65 convECDSAP256PublicKeyFromPEM(in char[] pem) @safe
{
	return convPublicKeyFromPEM!DefaultECDSAP256Engine(pem);
}
/// ditto
DERBinary convECDSAP256PublicKeyToDER(in BinaryKey!65 pubKey) @safe
{
	return convPublicKeyToDER!DefaultECDSAP256Engine(pubKey);
}
/// ditto
BinaryKey!65 convECDSAP256PublicKeyFromDER(in ubyte[] der) @safe
{
	return convPublicKeyFromDER!DefaultECDSAP256Engine(der);
}


/// ditto
PEMString convECDSAP256KPrivateKeyToPEM(in BinaryKey!32 prvKey) @safe
{
	return convPrivateKeyToPEM!DefaultECDSAP256KEngine(prvKey);
}
/// ditto
BinaryKey!32 convECDSAP256KPrivateKeyFromPEM(in char[] pem) @safe
{
	return convPrivateKeyFromPEM!DefaultECDSAP256KEngine(pem);
}
/// ditto
DERBinary convECDSAP256KPrivateKeyToDER(in BinaryKey!32 prvKey) @safe
{
	return convPrivateKeyToDER!DefaultECDSAP256KEngine(prvKey);
}
/// ditto
BinaryKey!32 convECDSAP256KPrivateKeyFromDER(in ubyte[] der) @safe
{
	return convPrivateKeyFromDER!DefaultECDSAP256KEngine(der);
}

/// ditto
PEMString convECDSAP256KPublicKeyToPEM(in BinaryKey!65 pubKey) @safe
{
	return convPublicKeyToPEM!DefaultECDSAP256KEngine(pubKey);
}
/// ditto
BinaryKey!65 convECDSAP256KPublicKeyFromPEM(in char[] pem) @safe
{
	return convPublicKeyFromPEM!DefaultECDSAP256KEngine(pem);
}
/// ditto
DERBinary convECDSAP256KPublicKeyToDER(in BinaryKey!65 pubKey) @safe
{
	return convPublicKeyToDER!DefaultECDSAP256KEngine(pubKey);
}
/// ditto
BinaryKey!65 convECDSAP256KPublicKeyFromDER(in ubyte[] der) @safe
{
	return convPublicKeyFromDER!DefaultECDSAP256KEngine(der);
}


/// ditto
PEMString convECDSAP384PrivateKeyToPEM(in BinaryKey!48 prvKey) @safe
{
	return convPrivateKeyToPEM!DefaultECDSAP384Engine(prvKey);
}
/// ditto
BinaryKey!48 convECDSAP384PrivateKeyFromPEM(in char[] pem) @safe
{
	return convPrivateKeyFromPEM!DefaultECDSAP384Engine(pem);
}
/// ditto
DERBinary convECDSAP384PrivateKeyToDER(in BinaryKey!48 prvKey) @safe
{
	return convPrivateKeyToDER!DefaultECDSAP384Engine(prvKey);
}
/// ditto
BinaryKey!48 convECDSAP384PrivateKeyFromDER(in ubyte[] der) @safe
{
	return convPrivateKeyFromDER!DefaultECDSAP384Engine(der);
}

/// ditto
PEMString convECDSAP384PublicKeyToPEM(in BinaryKey!97 pubKey) @safe
{
	return convPublicKeyToPEM!DefaultECDSAP384Engine(pubKey);
}
/// ditto
BinaryKey!97 convECDSAP384PublicKeyFromPEM(in char[] pem) @safe
{
	return convPublicKeyFromPEM!DefaultECDSAP384Engine(pem);
}
/// ditto
DERBinary convECDSAP384PublicKeyToDER(in BinaryKey!97 pubKey) @safe
{
	return convPublicKeyToDER!DefaultECDSAP384Engine(pubKey);
}
/// ditto
BinaryKey!97 convECDSAP384PublicKeyFromDER(in ubyte[] der) @safe
{
	return convPublicKeyFromDER!DefaultECDSAP384Engine(der);
}


/// ditto
PEMString convECDSAP521PrivateKeyToPEM(in BinaryKey!66 prvKey) @safe
{
	return convPrivateKeyToPEM!DefaultECDSAP521Engine(prvKey);
}
/// ditto
BinaryKey!66 convECDSAP521PrivateKeyFromPEM(in char[] pem) @safe
{
	return convPrivateKeyFromPEM!DefaultECDSAP521Engine(pem);
}
/// ditto
DERBinary convECDSAP521PrivateKeyToDER(in BinaryKey!66 prvKey) @safe
{
	return convPrivateKeyToDER!DefaultECDSAP521Engine(prvKey);
}
/// ditto
BinaryKey!66 convECDSAP521PrivateKeyFromDER(in ubyte[] der) @safe
{
	return convPrivateKeyFromDER!DefaultECDSAP521Engine(der);
}

/// ditto
PEMString convECDSAP521PublicKeyToPEM(in BinaryKey!133 pubKey) @safe
{
	return convPublicKeyToPEM!DefaultECDSAP521Engine(pubKey);
}
/// ditto
BinaryKey!133 convECDSAP521PublicKeyFromPEM(in char[] pem) @safe
{
	return convPublicKeyFromPEM!DefaultECDSAP521Engine(pem);
}
/// ditto
DERBinary convECDSAP521PublicKeyToDER(in BinaryKey!133 pubKey) @safe
{
	return convPublicKeyToDER!DefaultECDSAP521Engine(pubKey);
}
/// ditto
BinaryKey!133 convECDSAP521PublicKeyFromDER(in ubyte[] der) @safe
{
	return convPublicKeyFromDER!DefaultECDSAP521Engine(der);
}

@safe unittest
{
	enum testMsg = "Hello, World!".representation;
	void test(alias createPrv, alias createPub,
		alias raw2pemPrv, alias raw2derPrv, alias pem2rawPrv, alias der2rawPrv,
		alias raw2pemPub, alias raw2derPub, alias pem2rawPub, alias der2rawPub,
		alias TestSigner, alias TestVerifier)() @trusted
	{
		auto prv = createPrv();
		auto pub = createPub(prv);
		auto prvPem = raw2pemPrv(prv);
		auto pubPem = raw2pemPub(pub);
		auto prvDer = raw2derPrv(prv);
		auto pubDer = raw2derPub(pub);
		auto sign1 = TestSigner(prv).sign(testMsg);
		auto sign2 = TestSigner(prvDer).sign(testMsg);
		auto sign3 = TestSigner(prvPem).sign(testMsg);
		auto sign4 = TestSigner(pem2rawPrv(prvPem)).sign(testMsg);
		auto sign5 = TestSigner(der2rawPrv(prvDer)).sign(testMsg);
		assert(TestVerifier(pub).verify(sign1, testMsg));
		assert(TestVerifier(pubDer).verify(sign1, testMsg));
		assert(TestVerifier(pubPem).verify(sign1, testMsg));
		assert(TestVerifier(pub).verify(sign2, testMsg));
		assert(TestVerifier(pubDer).verify(sign2, testMsg));
		assert(TestVerifier(pubPem).verify(sign2, testMsg));
		assert(TestVerifier(pub).verify(sign3, testMsg));
		assert(TestVerifier(pubDer).verify(sign3, testMsg));
		assert(TestVerifier(pubPem).verify(sign3, testMsg));
		assert(TestVerifier(pem2rawPub(pubPem)).verify(sign4, testMsg));
		assert(TestVerifier(der2rawPub(pubDer)).verify(sign5, testMsg));
	}
	
	if (!isOpenSSLCmdEngine!DefaultEd25519Engine
		|| (isCommandExisting(defaultOpenSSLCommand)
			&& getOpenSSLCmdVerseion(defaultOpenSSLCommand) >= SemVer(3, 0, 1)))
	{
		test!(createEd25519PrivateKey, createEd25519PublicKey,
			convEd25519PrivateKeyToPEM, convEd25519PrivateKeyToDER,
			convEd25519PrivateKeyFromPEM, convEd25519PrivateKeyFromDER,
			convEd25519PublicKeyToPEM, convEd25519PublicKeyToDER,
			convEd25519PublicKeyFromPEM, convEd25519PublicKeyFromDER,
			Ed25519Signer!(), Ed25519Verifier!())();
	}
	
	test!(createECDSAP256PrivateKey, createECDSAP256PublicKey,
		convECDSAP256PrivateKeyToPEM, convECDSAP256PrivateKeyToDER,
		convECDSAP256PrivateKeyFromPEM, convECDSAP256PrivateKeyFromDER,
		convECDSAP256PublicKeyToPEM, convECDSAP256PublicKeyToDER,
		convECDSAP256PublicKeyFromPEM, convECDSAP256PublicKeyFromDER,
		ECDSAP256Signer!(), ECDSAP256Verifier!())();
	
	test!(createECDSAP256KPrivateKey, createECDSAP256KPublicKey,
		convECDSAP256KPrivateKeyToPEM, convECDSAP256KPrivateKeyToDER,
		convECDSAP256KPrivateKeyFromPEM, convECDSAP256KPrivateKeyFromDER,
		convECDSAP256KPublicKeyToPEM, convECDSAP256KPublicKeyToDER,
		convECDSAP256KPublicKeyFromPEM, convECDSAP256KPublicKeyFromDER,
		ECDSAP256KSigner!(), ECDSAP256KVerifier!())();
	
	test!(createECDSAP384PrivateKey, createECDSAP384PublicKey,
		convECDSAP384PrivateKeyToPEM, convECDSAP384PrivateKeyToDER,
		convECDSAP384PrivateKeyFromPEM, convECDSAP384PrivateKeyFromDER,
		convECDSAP384PublicKeyToPEM, convECDSAP384PublicKeyToDER,
		convECDSAP384PublicKeyFromPEM, convECDSAP384PublicKeyFromDER,
		ECDSAP384Signer!(), ECDSAP384Verifier!())();
	
	test!(createECDSAP521PrivateKey, createECDSAP521PublicKey,
		convECDSAP521PrivateKeyToPEM, convECDSAP521PrivateKeyToDER,
		convECDSAP521PrivateKeyFromPEM, convECDSAP521PrivateKeyFromDER,
		convECDSAP521PublicKeyToPEM, convECDSAP521PublicKeyToDER,
		convECDSAP521PublicKeyFromPEM, convECDSAP521PublicKeyFromDER,
		ECDSAP521Signer!(), ECDSAP521Verifier!())();
}

/*******************************************************************************
 * Methods of ECDSA P256 Signature format convertion
 * 
 * DER format:
 * - SEQUENCE
 *   - INTEGER: R
 *   - INTEGER: S
 * BIN format:
 * - ubyte[32]: R
 * - ubyte[32]: S
 */
bin_t convECDSASignDer2Bin(in ubyte[] der)
{
	const(ubyte)[] dat = der[];
	auto seq = decasn1seq(dat);
	if (der.length <= 72)
	{
		auto r = decasn1bn(seq, 32);
		auto s = decasn1bn(seq, 32);
		return (r ~ s).assumeUnique;
	}
	else if (der.length <= 104)
	{
		auto r = decasn1bn(seq, 48);
		auto s = decasn1bn(seq, 48);
		return (r ~ s).assumeUnique;
	}
	else if (der.length <= 142)
	{
		auto r = decasn1bn(seq, 66);
		auto s = decasn1bn(seq, 66);
		return (r ~ s).assumeUnique;
	}
	else enforce(false, "Unsupported signature");
	return null;
}
/// ditto
bin_t convECDSASignBin2Der(in ubyte[] bin)
{
	switch (bin.length)
	{
	case 64:
		return encasn1seq(encasn1bn(bin[0..32].assumeUnique) ~ encasn1bn(bin[32..$].assumeUnique));
	case 96:
		return encasn1seq(encasn1bn(bin[0..48].assumeUnique) ~ encasn1bn(bin[48..$].assumeUnique));
	case 132:
		return encasn1seq(encasn1bn(bin[0..66].assumeUnique) ~ encasn1bn(bin[66..$].assumeUnique));
	default:
		enforce(false, "Unsupported signature");
	}
	return null;
}
