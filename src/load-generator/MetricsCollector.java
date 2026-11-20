import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.io.PrintWriter;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicLong;

public class MetricsCollector {
    private final ConcurrentLinkedQueue<Long> latenciesNano = new ConcurrentLinkedQueue<>();
    private final AtomicLong successCount = new AtomicLong(0);
    private final AtomicLong errorCount = new AtomicLong(0);
    private volatile boolean isRecording = false;

    public void startRecording() {
        latenciesNano.clear();
        successCount.set(0);
        errorCount.set(0);
        isRecording = true;
    }

    public void stopRecording() {
        isRecording = false;
    }

    public void recordSuccess(long rttNano) {
        if (!isRecording) return;
        latenciesNano.add(rttNano);
        successCount.incrementAndGet();
    }

    public void recordError() {
        if (!isRecording) return;
        errorCount.incrementAndGet();
    }

    public void exportResults(int runId, int clients, int durationSec, int payloadSize, String csvPath, String jsonPath) {
        List<Long> sortedLatencies = new ArrayList<>(latenciesNano);
        Collections.sort(sortedLatencies);

        long totalSuccess = successCount.get();
        long totalErrors = errorCount.get();
        long totalRequests = totalSuccess + totalErrors;

        double throughput = (double) totalSuccess / durationSec;
        double errorRate = totalRequests == 0 ? 0.0 : ((double) totalErrors / totalRequests) * 100.0;

        double avgLatencyMs = 0.0;
        double p95LatencyMs = 0.0;

        if (!sortedLatencies.isEmpty()) {
            long sumNano = 0;
            for (long lat : sortedLatencies) {
                sumNano += lat;
            }
            avgLatencyMs = (sumNano / (double) sortedLatencies.size()) / 1_000_000.0;

            int p95Index = (int) Math.ceil(0.95 * sortedLatencies.size()) - 1;
            p95Index = Math.max(0, Math.min(p95Index, sortedLatencies.size() - 1));
            p95LatencyMs = sortedLatencies.get(p95Index) / 1_000_000.0;
        }

        System.out.println("\n================ BENCHMARK SUMMARY ================");
        System.out.printf("Run ID: %d | Clients: %d | Duration: %ds | Payload: %d B%n", runId, clients, durationSec, payloadSize);
        System.out.printf("Total Requests : %d (Success: %d, Errors: %d)%n", totalRequests, totalSuccess, totalErrors);
        System.out.printf("Throughput     : %.2f req/s%n", throughput);
        System.out.printf("Avg Latency    : %.4f ms%n", avgLatencyMs);
        System.out.printf("p95 Latency    : %.4f ms%n", p95LatencyMs);
        System.out.printf("Error Rate     : %.2f%%%n", errorRate);
        System.out.println("===================================================\n");

        ensureParentDirExists(csvPath);
        ensureParentDirExists(jsonPath);

        File csvFile = new File(csvPath);
        boolean isNewFile = !csvFile.exists() || csvFile.length() == 0;
        try (PrintWriter pw = new PrintWriter(new FileWriter(csvFile, true))) {
            if (isNewFile) {
                pw.println("run_id,clients,duration_sec,payload_bytes,total_success,total_errors,throughput_req_s,avg_latency_ms,p95_latency_ms,error_rate_percent");
            }
            pw.printf("%d,%d,%d,%d,%d,%d,%.2f,%.4f,%.4f,%.2f%n",
                    runId, clients, durationSec, payloadSize, totalSuccess, totalErrors,
                    throughput, avgLatencyMs, p95LatencyMs, errorRate);
        } catch (IOException e) {
            System.err.println("[ERROR] Khong the ghi CSV: " + e.getMessage());
        }

        try (PrintWriter pw = new PrintWriter(new FileWriter(jsonPath))) {
            pw.println("{");
            pw.printf("  \"run_id\": %d,%n", runId);
            pw.printf("  \"clients\": %d,%n", clients);
            pw.printf("  \"duration_sec\": %d,%n", durationSec);
            pw.printf("  \"payload_bytes\": %d,%n", payloadSize);
            pw.printf("  \"total_success\": %d,%n", totalSuccess);
            pw.printf("  \"total_errors\": %d,%n", totalErrors);
            pw.printf("  \"throughput_req_per_sec\": %.2f,%n", throughput);
            pw.printf("  \"avg_latency_ms\": %.4f,%n", avgLatencyMs);
            pw.printf("  \"p95_latency_ms\": %.4f,%n", p95LatencyMs);
            pw.printf("  \"error_rate_percent\": %.2f%n", errorRate);
            pw.println("}");
        } catch (IOException e) {
            System.err.println("[ERROR] Khong the ghi JSON: " + e.getMessage());
        }
    }

    private void ensureParentDirExists(String filePath) {
        File file = new File(filePath);
        File parent = file.getParentFile();
        if (parent != null && !parent.exists()) {
            parent.mkdirs();
        }
    }
}