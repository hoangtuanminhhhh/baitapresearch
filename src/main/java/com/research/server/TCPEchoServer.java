package com.research.server;

import com.research.common.Protocol;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.file.Paths;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.atomic.AtomicLong;

/**
 * TCP Echo Server - mo hinh: BLOCKING SOCKET + FIXED THREAD POOL (ExecutorService).
 *
 * Frame (big-endian), dung chung cho request va response:
 *   [4 byte: N = do dai body][8 byte: requestId][N-8 byte: payload]
 *   (payload khuyen nghi 1024 byte => N = 1032, tong frame = 1036 byte)
 *
 * Vong doi: acceptor thread accept() -> giao Socket cho ClientHandler chay tren thread pool.
 * LUU Y: poolSize phai >= so client dong thoi (>= 50), neu khong client du phai cho trong hang doi
 *        va se bi do latency sai.
 */
public class TCPEchoServer {

    private final String host;
    private final int port;
    private final int poolSize;
    final int timeoutMs;
    final boolean verbose;

    private ServerSocket serverSocket;
    private ExecutorService pool;
    private Thread acceptThread;
    private volatile boolean running;

    // Thong ke (cac ClientHandler cap nhat)
    public final AtomicLong accepted = new AtomicLong();
    public final AtomicLong requests = new AtomicLong();
    public final AtomicLong protocolErrors = new AtomicLong();
    public final AtomicLong timeouts = new AtomicLong();
    public final AtomicLong abruptDisconnects = new AtomicLong();
    public final AtomicLong cleanDisconnects = new AtomicLong();

    public TCPEchoServer(String host, int port, int poolSize, int timeoutMs, boolean verbose) {
        this.host = host;
        this.port = port;
        this.poolSize = poolSize;
        this.timeoutMs = timeoutMs;
        this.verbose = verbose;
    }

    public void start() throws IOException {
        serverSocket = new ServerSocket();
        serverSocket.setReuseAddress(true);
        serverSocket.bind(new InetSocketAddress(host, port), 256);
        pool = Executors.newFixedThreadPool(poolSize);
        running = true;
        acceptThread = new Thread(this::acceptLoop, "acceptor");
        acceptThread.start();
        log("Listening on " + host + ":" + getPort() + " pool=" + poolSize + " readTimeout=" + timeoutMs + "ms");
    }

    public int getPort() {
        return serverSocket.getLocalPort();
    }

    public void stop() {
        running = false;
        try { serverSocket.close(); } catch (IOException ignored) { }
        pool.shutdownNow();
    }

    private void acceptLoop() {
        while (running) {
            try {
                Socket s = serverSocket.accept();
                accepted.incrementAndGet();
                pool.execute(new ClientHandler(s, this));
            } catch (RejectedExecutionException e) {
                break;                                   // pool da shutdown
            } catch (IOException e) {
                if (running) log("accept error: " + e);  // loi accept khong duoc lam chet server
            }
        }
    }

    void log(String msg) {
        if (verbose) System.err.println("[server] " + msg);
    }

    public String statsLine() {
        return String.format("accepted=%d requests=%d cleanClose=%d abruptClose=%d timeouts=%d protocolErrors=%d",
                accepted.get(), requests.get(), cleanDisconnects.get(), abruptDisconnects.get(),
                timeouts.get(), protocolErrors.get());
    }

    public static void main(String[] args) throws Exception {
        String host = "0.0.0.0", cpuLog = null;
        int port = 9000, pool = 256, timeout = 30000;
        long cpuIntervalMs = 1000;
        boolean verbose = false;
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--host": host = args[++i]; break;
                case "--port": port = Integer.parseInt(args[++i]); break;
                case "--pool": pool = Integer.parseInt(args[++i]); break;
                case "--timeout-ms": timeout = Integer.parseInt(args[++i]); break;
                case "--cpu-log": cpuLog = args[++i]; break;
                case "--cpu-interval-ms": cpuIntervalMs = Long.parseLong(args[++i]); break;
                case "--verbose": verbose = true; break;
                default:
                    System.err.println("Usage: TCPEchoServer [--host H] [--port P] [--pool N] [--timeout-ms MS]\n"
                            + "                     [--cpu-log file.csv] [--cpu-interval-ms MS] [--verbose]");
                    System.exit(1);
            }
        }
        TCPEchoServer server = new TCPEchoServer(host, port, pool, timeout, verbose);
        CpuMonitor cpu = new CpuMonitor(cpuIntervalMs, cpuLog == null ? null : Paths.get(cpuLog));
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            cpu.close();
            System.err.println("[server] stats: " + server.statsLine()
                    + String.format(" avgCpu=%.1f%%ofOneCore", cpu.averagePctOfOneCore()));
        }));
        server.start();
        cpu.start();
        Thread.currentThread().join(); // chay den khi bi kill / Ctrl+C
    }
}
