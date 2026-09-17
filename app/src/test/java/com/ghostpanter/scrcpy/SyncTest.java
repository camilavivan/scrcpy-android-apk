package com.ghostpanter.scrcpy;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Test;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

public class SyncTest {

    private static final String PATH = "/data/local/tmp/scrcpy-server.jar";
    private static final int    MODE = 0100644;
    private static final int    MTIME = 0x12345678;

    @Test
    public void emptyPayloadFraming() throws Exception {
        byte[] payload = new byte[0];
        ByteArrayOutputStream framed = new ByteArrayOutputStream();
        ByteArrayInputStream resp    = okayResponse();

        long total = Sync.push(new ByteArrayInputStream(payload), framed, resp, PATH, MODE, MTIME);
        assertEquals(0L, total);

        byte[] bytes = framed.toByteArray();
        int pos = 0;

        // SEND + le32(headerLen) + header
        String header = PATH + "," + MODE;
        byte[] hb = header.getBytes(StandardCharsets.UTF_8);
        pos = assertTag(bytes, pos, "SEND");
        assertEquals(hb.length, Wire.readLe32(bytes, pos)); pos += 4;
        for (int i = 0; i < hb.length; i++, pos++) assertEquals(hb[i], bytes[pos]);

        // No DATA chunks for empty payload.
        // DONE + le32(mtime)
        pos = assertTag(bytes, pos, "DONE");
        assertEquals(MTIME, Wire.readLe32(bytes, pos)); pos += 4;

        assertEquals(bytes.length, pos);
    }

    @Test
    public void singleByteIsOneDataChunk() throws Exception {
        ByteArrayOutputStream framed = new ByteArrayOutputStream();
        long total = Sync.push(new ByteArrayInputStream(new byte[]{0x42}),
                framed, okayResponse(), PATH, MODE, MTIME);
        assertEquals(1L, total);

        byte[] bytes = framed.toByteArray();
        int pos = skipSendHeader(bytes);
        pos = assertTag(bytes, pos, "DATA");
        assertEquals(1, Wire.readLe32(bytes, pos)); pos += 4;
        assertEquals(0x42, bytes[pos]); pos += 1;
        pos = assertTag(bytes, pos, "DONE");
        assertEquals(MTIME, Wire.readLe32(bytes, pos)); pos += 4;
        assertEquals(bytes.length, pos);
    }

    @Test
    public void payloadLargerThanChunkSplits() throws Exception {
        int n = Sync.CHUNK + 1;
        byte[] payload = new byte[n];
        for (int i = 0; i < n; i++) payload[i] = (byte) i;

        ByteArrayOutputStream framed = new ByteArrayOutputStream();
        long total = Sync.push(new ByteArrayInputStream(payload),
                framed, okayResponse(), PATH, MODE, MTIME);
        assertEquals(n, total);

        byte[] bytes = framed.toByteArray();
        int pos = skipSendHeader(bytes);

        // First DATA = full chunk
        pos = assertTag(bytes, pos, "DATA");
        assertEquals(Sync.CHUNK, Wire.readLe32(bytes, pos)); pos += 4;
        pos += Sync.CHUNK;

        // Second DATA = the remaining one byte
        pos = assertTag(bytes, pos, "DATA");
        assertEquals(1, Wire.readLe32(bytes, pos)); pos += 4;
        pos += 1;

        pos = assertTag(bytes, pos, "DONE");
        assertEquals(MTIME, Wire.readLe32(bytes, pos)); pos += 4;
        assertEquals(bytes.length, pos);
    }

    @Test
    public void failResponseRaises() {
        ByteArrayOutputStream framed = new ByteArrayOutputStream();
        ByteArrayInputStream resp = failResponse("disk full");
        try {
            Sync.push(new ByteArrayInputStream(new byte[]{1, 2, 3}), framed, resp,
                    PATH, MODE, MTIME);
            fail("expected IOException");
        } catch (IOException e) {
            assertTrue(e.getMessage(), e.getMessage().contains("disk full"));
            assertTrue(e.getMessage(), e.getMessage().startsWith("sync FAIL"));
        }
    }

    private static ByteArrayInputStream okayResponse() {
        byte[] r = new byte[8];
        r[0] = 'O'; r[1] = 'K'; r[2] = 'A'; r[3] = 'Y';
        // length 0
        return new ByteArrayInputStream(r);
    }

    private static ByteArrayInputStream failResponse(String msg) {
        byte[] mb = msg.getBytes(StandardCharsets.UTF_8);
        byte[] r = new byte[8 + mb.length];
        r[0] = 'F'; r[1] = 'A'; r[2] = 'I'; r[3] = 'L';
        Wire.writeLe32(r, 4, mb.length);
        System.arraycopy(mb, 0, r, 8, mb.length);
        return new ByteArrayInputStream(r);
    }

    private static int assertTag(byte[] bytes, int pos, String tag) {
        for (int i = 0; i < 4; i++) {
            assertEquals("tag pos=" + pos + " idx=" + i,
                    (byte) tag.charAt(i), bytes[pos + i]);
        }
        return pos + 4;
    }

    private static int skipSendHeader(byte[] bytes) {
        // SEND + le32(len) + header
        int pos = 4;
        int len = Wire.readLe32(bytes, pos);
        return pos + 4 + len;
    }
}
