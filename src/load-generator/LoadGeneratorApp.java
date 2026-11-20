import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;

public class LoadGeneratorApp {
    public static void main(String[] args) throws InterruptedException {
        String host = "127.0.0.1";
        int port = 8080;
        int clients = 1;
        int durationSec = 20;
        int warmupSec = 5;
        int payloadSize = 1024;
        int runId = 1;
        String csvPath = "experiments/raw-data/benchmark_results.csv";
        String jsonPath = "experiments/raw-data/run_latest.json";
        boolean testInvalid = false;
        boolean killEarly = false;

        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--host": host = args[++i]; break;
                case "--port": port = Integer.parseInt(args[++i]); break;
                case "--clients": clients = Integer.parseInt(args[++i]); break;
                case "--duration": durationSec = Integer.parseInt(args[++i]); break;
                case "--warmup": warmupSec = Integer.parseInt(args[++i]); break;
                case "--payload": payloadSize = Integer.parseInt(args[++i]); break;
                case "--run-id": runId = Integer.parseInt(args[++i]); break;
                case "--csv": csvPath = args[++i]; break;
                case "--json": jsonPath = args[++i]; break;
                case "--test-invalid": testInvalid = true; break;
                case "--kill-early": killEarly = true; break;
                default:
                    System.err.println("Tham so khong hop le: " + args[i]);
            }
        }

        MetricsCollector collector = new MetricsCollector();
        AtomicBoolean running = new AtomicBoolean(true);
        ExecutorService executor = Executors.newFixedThreadPool(clients);

        System.out.printf("[INIT] Ket noi toi %s:%d | Clients=%d | Warmup=%ds | Duration=%ds | Payload=%dB%n",
                host, port, clients, warmupSec, durationSec, payloadSize);

        for (int i = 0; i < clients; i++) {
            executor.submit(new BenchmarkWorker(host, port, payloadSize, collector, running, testInvalid, killEarly));
        }

        if (warmupSec > 0 && !testInvalid && !killEarly) {
            System.out.println("[WARM-UP] Dang lam nong he thong trong " + warmupSec + " giay...");
            Thread.sleep(warmupSec * 1000L);
        }

        System.out.println("[MEASURE] Bat dau thu thap du lieu trong " + durationSec + " giay...");
        collector.startRecording();
        Thread.sleep(durationSec * 1000L);
        collector.stopRecording();

        System.out.println("[STOP] Dang dong toan bo luong Client...");
        running.set(false);
        executor.shutdownNow();
        executor.awaitTermination(5, TimeUnit.SECONDS);

        collector.exportResults(runId, clients, durationSec, payloadSize, csvPath, jsonPath);
    }
}