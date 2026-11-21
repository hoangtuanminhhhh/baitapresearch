package com.research.server;

import java.io.IOException;
import java.io.PrintWriter;
import java.lang.management.ManagementFactory;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Locale;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;

/**
 * Do CPU cua CHINH process server moi giay bang com.sun.management.OperatingSystemMXBean.
 *
 * Cach tinh: getProcessCpuTime() la tong CPU time (ns) process da dung. Moi chu ky:
 *   cpu_pct_of_one_core = (delta CPU time / delta thoi gian thuc) * 100   (100% = dung het 1 core, co the > 100%)
 *   cpu_pct_normalized  = cpu_pct_of_one_core / so core                   (0..100% cua ca may)
 * Them cot system_cpu_pct (getCpuLoad) = tai CPU cua CA MAY (gom ca load generator) de doi chieu.
 *
 * CSV: epoch_ms,elapsed_s,cpu_pct_of_one_core,cpu_pct_normalized,system_cpu_pct   (flush moi dong)
 */
public class CpuMonitor implements AutoCloseable {
    private final com.sun.management.OperatingSystemMXBean os =
            (com.sun.management.OperatingSystemMXBean) ManagementFactory.getOperatingSystemMXBean();
    private final int cores = os.getAvailableProcessors();
    private final long intervalMs;
    private final PrintWriter out;
    private final ScheduledExecutorService ex = Executors.newSingleThreadScheduledExecutor(r -> {
        Thread t = new Thread(r, "cpu-monitor");
        t.setDaemon(true);
        return t;
    });

    private long lastCpuNs, lastWallNs, startWallNs;
    private double sumPct;
    private long samples;

    public CpuMonitor(long intervalMs, Path logFile) throws IOException {
        this.intervalMs = intervalMs;
        if (logFile != null) {
            if (logFile.getParent() != null) Files.createDirectories(logFile.getParent());
            out = new PrintWriter(Files.newBufferedWriter(logFile));
            out.println("epoch_ms,elapsed_s,cpu_pct_of_one_core,cpu_pct_normalized,system_cpu_pct");
            out.flush();
        } else {
            out = null;
        }
    }

    public void start() {
        lastCpuNs = os.getProcessCpuTime();
        lastWallNs = startWallNs = System.nanoTime();
        ex.scheduleAtFixedRate(this::sample, intervalMs, intervalMs, TimeUnit.MILLISECONDS);
    }

    private synchronized void sample() {
        try {
            long cpu = os.getProcessCpuTime(), wall = System.nanoTime();
            if (cpu < 0 || wall <= lastWallNs) return; // he dieu hanh khong ho tro
            double pctCore = 100.0 * (cpu - lastCpuNs) / (double) (wall - lastWallNs);
            double pctNorm = pctCore / cores;
            double sys = os.getCpuLoad() * 100.0;       // < 0 neu chua co du lieu
            lastCpuNs = cpu;
            lastWallNs = wall;
            sumPct += pctCore;
            samples++;
            if (out != null) {
                out.printf(Locale.ROOT, "%d,%.1f,%.2f,%.2f,%s%n", System.currentTimeMillis(),
                        (wall - startWallNs) / 1e9, pctCore, pctNorm, sys >= 0 ? String.format(Locale.ROOT, "%.2f", sys) : "");
                out.flush();
            }
        } catch (Throwable t) {
            // khong de exception huy lich do (scheduleAtFixedRate se dung neu task nem exception)
        }
    }

    /** Trung binh (% cua 1 core) cua tat ca cac mau tu luc start(). */
    public synchronized double averagePctOfOneCore() {
        return samples == 0 ? Double.NaN : sumPct / samples;
    }

    @Override
    public void close() {
        ex.shutdownNow();
        if (out != null) out.close();
    }
}
