package com.research.server;

import com.research.common.Protocol;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.OutputStream;
import java.net.Socket;
import java.net.SocketTimeoutException;

/**
 * Xu ly MOT ket noi client (chay tren 1 thread cua pool) cho den khi client dong / loi / timeout.
 * Moi loi chi anh huong rieng ket noi nay: bat het exception, luon dong socket trong try-with-resources.
 */
class ClientHandler implements Runnable {
    private final Socket socket;
    private final TCPEchoServer server;

    ClientHandler(Socket socket, TCPEchoServer server) {
        this.socket = socket;
        this.server = server;
    }

    @Override
    public void run() {
        String peer = String.valueOf(socket.getRemoteSocketAddress());
        try (Socket s = socket) {                     // try-with-resources => luon giai phong socket
            s.setTcpNoDelay(true);
            s.setSoTimeout(server.timeoutMs);         // read timeout: client im lang qua lau => dong
            DataInputStream in = new DataInputStream(new BufferedInputStream(s.getInputStream(), 8192));
            OutputStream out = s.getOutputStream();

            while (true) {
                // 1) Doc 4 byte do dai. Byte dau = -1 nghia la client dong dung ranh gioi message.
                int b0 = in.read();
                if (b0 < 0) {
                    server.cleanDisconnects.incrementAndGet();
                    break;
                }
                int len = (b0 << 24) | (in.readUnsignedByte() << 16)
                        | (in.readUnsignedByte() << 8) | in.readUnsignedByte();

                // 2) Kiem tra do dai hop le TRUOC khi cap phat bo nho (chong payload khong lo / du lieu rac)
                if (len < Protocol.ID_BYTES || len > Protocol.MAX_BODY) {
                    server.protocolErrors.incrementAndGet();
                    server.log(peer + " invalid length " + len + " -> close");
                    break;
                }

                // 3) Doc DU len byte (readFully lap cho den khi du) - KHONG gia dinh 1 lan read = 1 message
                byte[] frame = new byte[Protocol.HEADER_BYTES + len];
                frame[0] = (byte) (len >>> 24);
                frame[1] = (byte) (len >>> 16);
                frame[2] = (byte) (len >>> 8);
                frame[3] = (byte) len;
                in.readFully(frame, Protocol.HEADER_BYTES, len);

                // 4) Echo nguyen khung (requestId + payload) lai
                out.write(frame);
                out.flush();
                server.requests.incrementAndGet();
            }
        } catch (SocketTimeoutException e) {
            server.timeouts.incrementAndGet();
            server.log(peer + " read timeout -> close");
        } catch (EOFException e) {
            server.abruptDisconnects.incrementAndGet(); // dong giua chung message
            server.log(peer + " closed mid-message");
        } catch (IOException e) {
            server.abruptDisconnects.incrementAndGet(); // connection reset, broken pipe...
            server.log(peer + " I/O error: " + e);
        } catch (RuntimeException e) {
            server.protocolErrors.incrementAndGet();    // chot chan cuoi: khong de loi lan ra thread pool
            server.log(peer + " unexpected: " + e);
        }
    }
}
