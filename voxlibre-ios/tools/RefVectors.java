import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Locale;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * Reference-vector generator. The pure functions below are copied VERBATIM from the
 * original VoxLibre Java sources (RingProtocol, RingConfig, OpusAudio.writeWav) with the
 * Android types stripped. Output is Swift source for Tests/VoxLibreCoreTests/Vectors.swift.
 */
public class RefVectors {
    // ---- identity used for the vectors ----
    static String bindKey = "0123456789abcdef0123456789ABCDEF";
    static String userId = "user_test123";
    static String fwid = "FW1234";
    static String sn = "SN0001";
    static String mac = "AA:BB:CC:DD:EE:FF";

    // ---- RingProtocol (verbatim) ----
    static int seq = 1;
    static byte[] enc(int op, byte[] d) {
        seq = (seq + 1) & 0xFFFF;
        if (seq == 0)
            seq = 1;
        int ln = d.length + 1;
        byte[] f = new byte[7 + d.length + 3];
        f[0] = (byte) 0xAA;
        f[1] = 0x55;
        f[2] = (byte) (seq >> 8);
        f[3] = (byte) seq;
        f[4] = (byte) (ln >> 8);
        f[5] = (byte) ln;
        f[6] = (byte) op;
        System.arraycopy(d, 0, f, 7, d.length);
        f[7 + d.length] = 0;
        f[8 + d.length] = 0x0D;
        f[9 + d.length] = 0x0A;
        return f;
    }
    static String hex(byte[] a) {
        StringBuilder s = new StringBuilder();
        for (byte x : a) s.append(String.format("%02x", x));
        return s.toString();
    }
    static String hmacHex(String k, String m) {
        try {
            Mac x = Mac.getInstance("HmacSHA256");
            x.init(new SecretKeySpec(k.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            return hex(x.doFinal(m.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }
    static String kh() {
        return hex(bindKey.getBytes(StandardCharsets.UTF_8));
    }
    static String content(String n) {
        return fwid + "_" + sn + "_" + mac + "_" + n;
    }
    static byte[] sendRead(String name) {
        byte[] nm = name.getBytes(StandardCharsets.UTF_8);
        byte[] d = new byte[2 + nm.length + 5];
        d[0] = 1;
        d[1] = (byte) nm.length;
        System.arraycopy(nm, 0, d, 2, nm.length);
        return d;
    }
    static byte[] sendDelete(String name) {
        byte[] nm = name.getBytes(StandardCharsets.UTF_8);
        byte[] p = new byte[2 + nm.length];
        p[0] = 0x02;
        p[1] = (byte) nm.length;
        System.arraycopy(nm, 0, p, 2, nm.length);
        return p;
    }
    static byte[] frameData(byte[] v) {
        return (v.length >= 10)
                ? Arrays.copyOfRange(v, 7, 7 + ((v[4] & 0xFF) << 8 | (v[5] & 0xFF)) - 1)
                : new byte[0];
    }
    static byte[] appResponse(String nonce) {
        String an = "app_" + nonce, inner = hmacHex(kh(), an), aa = hmacHex(inner, content(an));
        byte[] anb = an.getBytes(StandardCharsets.UTF_8), aab = aa.getBytes(StandardCharsets.UTF_8);
        byte[] pl = new byte[2 + anb.length + 1 + aab.length];
        pl[0] = 3;
        pl[1] = (byte) anb.length;
        System.arraycopy(anb, 0, pl, 2, anb.length);
        pl[2 + anb.length] = '@';
        System.arraycopy(aab, 0, pl, 3 + anb.length, aab.length);
        return pl;
    }
    static byte[] userIdPayload() {
        byte[] uid = userId.getBytes(StandardCharsets.UTF_8);
        byte[] p = new byte[2 + uid.length];
        p[0] = 3;
        p[1] = (byte) uid.length;
        System.arraycopy(uid, 0, p, 2, uid.length);
        return p;
    }

    // ---- RingProtocol.handleCtrl telemetry decode (verbatim arithmetic) ----
    static String decodeF2(byte[] d) {
        String hwVer = ((d[1] >> 4) & 15) + "." + (d[1] & 15) + "." + (d[2] & 0xFF);
        String fwVer = ((d[3] >> 4) & 15) + "." + (d[3] & 15) + "."
                + String.format(Locale.US, "%02d", d[4] & 0xFF);
        int battStatus = d[5] & 0xFF, batt = d[6] & 0xFF, slaveRssi = 256 - (d[8] & 0xFF),
            hostRssi = 256 - (d[9] & 0xFF);
        int volt = ((d[10] & 0xFF) << 8) | (d[11] & 0xFF);
        String model = "?";
        if (d.length > 14) {
            int ml = d[14] & 0xFF;
            if (ml > 0 && d.length >= 15 + ml)
                model = new String(d, 15, ml, StandardCharsets.ISO_8859_1);
        }
        return "hw=" + hwVer + " fw=" + fwVer + " battSt=" + battStatus + " batt=" + batt
                + " hostRssi=" + hostRssi + " volt=" + volt + " model=" + model;
    }
    static String decode14(byte[] d) {
        long storFree = ((long) (d[0] & 0xFF) << 24) | ((d[1] & 0xFF) << 16) | ((d[2] & 0xFF) << 8)
                | (d[3] & 0xFF);
        long storTot = ((long) (d[8] & 0xFF) << 24) | ((d[9] & 0xFF) << 16) | ((d[10] & 0xFF) << 8)
                | (d[11] & 0xFF);
        return "free=" + storFree + " tot=" + storTot;
    }

    // ---- RingConfig.parseDeviceInfo (verbatim, prefs stripped) ----
    static String parseDeviceInfo(byte[] d) {
        String sn = "", fwid = "";
        int o = 0;
        int snLen = d[o++] & 0xFF;
        if (o + snLen > d.length)
            return "short";
        sn = new String(d, o, snLen, StandardCharsets.US_ASCII);
        o += snLen;
        int macLen = d[o++] & 0xFF;
        o += macLen;
        if (o < d.length) {
            int fwLen = d[o++] & 0xFF;
            if (o + fwLen <= d.length)
                fwid = new String(d, o, fwLen, StandardCharsets.US_ASCII);
        }
        return "SN=" + sn + " FWID=" + fwid;
    }

    // ---- OpusAudio.writeWav header (verbatim) ----
    static byte[] wavHeader(int dataLen) {
        int rate = 48000, ch = 1;
        ByteBuffer hh = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN);
        hh.put("RIFF".getBytes())
                .putInt(36 + dataLen)
                .put("WAVE".getBytes())
                .put("fmt ".getBytes())
                .putInt(16)
                .putShort((short) 1)
                .putShort((short) ch)
                .putInt(rate)
                .putInt(rate * ch * 2)
                .putShort((short) (ch * 2))
                .putShort((short) 16)
                .put("data".getBytes())
                .putInt(dataLen);
        return hh.array();
    }

    static byte[] hexToBytes(String s) {
        byte[] r = new byte[s.length() / 2];
        for (int i = 0; i < r.length; i++) r[i] = (byte) Integer.parseInt(s.substring(2 * i, 2 * i + 2), 16);
        return r;
    }

    static void kv(String name, String value) {
        System.out.println("    static let " + name + " = \"" + value + "\"");
    }

    public static void main(String[] a) throws Exception {
        String nonce = "n0nc3_42";
        System.out.println("// GENERATED by scratchpad/RefVectors.java from the original Java logic. Do not edit by hand.");
        System.out.println("enum Ref {");
        kv("bindKey", bindKey);
        kv("userId", userId);
        kv("fwid", fwid);
        kv("sn", sn);
        kv("mac", mac);
        kv("nonce", nonce);
        kv("kh", kh());
        kv("contentNonce", content(nonce));
        kv("ringDauth", hmacHex(kh(), content(nonce)));
        String an = "app_" + nonce;
        kv("appName", an);
        kv("inner", hmacHex(kh(), an));
        kv("appResponsePayloadHex", hex(appResponse(nonce)));
        kv("userIdPayloadHex", hex(userIdPayload()));

        // Frame sequence exactly as the handshake would emit it (seq starts at 1 -> first frame seq 2).
        seq = 1;
        kv("frameProtoHex", hex(enc(0x82, new byte[] {0x05})));          // seq 2
        kv("frameDeviceInfoHex", hex(enc(0x80, new byte[0])));            // seq 3
        kv("frameUserIdHex", hex(enc(0x81, userIdPayload())));            // seq 4
        kv("frameRequestChallengeHex", hex(enc(0x82, new byte[] {0x01}))); // seq 5
        kv("frameAppResponseHex", hex(enc(0x82, appResponse(nonce))));    // seq 6
        kv("frameListHex", hex(enc(0x11, new byte[0])));                  // seq 7
        kv("frameReadHex", hex(enc(0x12, sendRead("amsg_1700000000_mono.opus")))); // seq 8
        kv("frameDeleteHex", hex(enc(0x17, sendDelete("amsg_1700000000_mono.json")))); // seq 9
        // wrap-around: set seq to 0xFFFE -> next 0xFFFF, next wraps to 0 -> forced to 1
        seq = 0xFFFE;
        kv("frameWrapAHex", hex(enc(0x30, new byte[] {0x01}))); // seq ffff
        kv("frameWrapBHex", hex(enc(0x25, new byte[0])));       // seq 1
        kv("frameWrapCHex", hex(enc(0x2a, new byte[] {0, 0}))); // seq 2

        // frameData round-trip on one of the frames
        seq = 1;
        byte[] f = enc(0x82, appResponse(nonce));
        kv("frameDataRoundTripOk", Arrays.equals(frameData(f), appResponse(nonce)) ? "yes" : "NO");

        // Device info (0x80) payload: [snLen][SN][macLen][MAC reversed][fwLen][FWID]
        byte[] sn_ = sn.getBytes(StandardCharsets.US_ASCII), fw_ = fwid.getBytes(StandardCharsets.US_ASCII);
        byte[] macRev = hexToBytes("FFEEDDCCBBAA");
        ByteBuffer di = ByteBuffer.allocate(1 + sn_.length + 1 + 6 + 1 + fw_.length);
        di.put((byte) sn_.length).put(sn_).put((byte) 6).put(macRev).put((byte) fw_.length).put(fw_);
        kv("deviceInfoHex", hex(di.array()));
        kv("deviceInfoParsed", parseDeviceInfo(di.array()));

        // 0xf2 status: [?][hw][hw][fw][fw][battSt][batt][?][slaveRssi][hostRssi][voltHi][voltLo][?][?][mlen][model...]
        byte[] f2 = hexToBytes("00" + "23" + "07" + "12" + "05" + "01" + "57" + "00" + "c8" + "c2" + "0f" + "a0" + "00" + "00"
                + "05" + hex("Timon".getBytes(StandardCharsets.ISO_8859_1)));
        kv("f2Hex", hex(f2));
        kv("f2Decoded", decodeF2(f2));
        // short f2 (no model)
        byte[] f2s = Arrays.copyOf(f2, 14);
        kv("f2ShortHex", hex(f2s));
        kv("f2ShortDecoded", decodeF2(f2s));
        // 0x14 storage: free u32 | 4 bytes | total u32
        byte[] s14 = hexToBytes("00200000" + "00000000" + "00400000");
        kv("s14Hex", hex(s14));
        kv("s14Decoded", decode14(s14));

        // WAV header for 11520 bytes of PCM
        kv("wavHeader11520Hex", hex(wavHeader(11520)));
        kv("wavHeader0Hex", hex(wavHeader(0)));
        System.out.println("}");
    }
}
