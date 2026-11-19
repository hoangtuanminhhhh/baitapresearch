import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.net.Socket;
import java.net.SocketTimeoutException;
import java.util.Arrays;
import java.util.Random;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;

public class BenchmarkWorker implements Runnable {
    private final String host;
    private final int port;
    private final int payloadSize;
    private final MetricsCollector collector;
    private final AtomicBoolean running;
    private final boolean testInvalidFrame;
    private final boolean killEarly;

    private static final AtomicLong globalRequestId = new AtomicLong(1);

    public BenchmarkWorker(String host, int port, int payloadSize, MetricsCollector collector,
                           AtomicBoolean running, boolean testInvalidFrame, boolean killEarly) {
        this.host = host;
        this.port = port;
        this.payloadSize = payloadSize;
        this.collector = collector;
        this.running = running;
        this.testInvalidFrame = testInvalidFrame;
        this.killEarly = killEarly;
    }

    @Override
    public void run() {
        byte[] sendPayload = new byte[payloadSize];
        new Random().nextBytes(sendPayload);

        try (Socket socket = new Socket(host, port)) {
            socket.setTcpNoDelay(true);
            socket.setSoTimeout(5000);

            DataOutputStream out = new DataOutputStream(socket.getOutputStream());
            DataInputStream in = new DataInputStream(socket.getInputStream());

            int localCount = 0;

            while (running.get() && !Thread.currentThread().isInterrupted()) {
                long reqId = globalRequestId.getAndIncrement();
                int frameBodyLength = 8 + payloadSize;

                if (testInvalidFrame) {
                    out.writeInt(999_999_999);
                    out.writeLong(reqId);
                    out.write(sendPayload, 0, Math.min(10, payloadSize));
                    out.flush();
                    collector.recordError();
                    break;
                }

                if (killEarly && localCount >= 5) {
                    socket.close();
                    break;
                }

                long startTime = System.nanoTime();
                try {
                    out.writeInt(frameBodyLength);
                    out.writeLong(reqId);
                    out.write(sendPayload);
                    out.flush();

                    int respLength = in.readInt();
                    if (respLength != frameBodyLength) {
                        collector.recordError();
                        break;
                    }

                    long respReqId = in.readLong();
                    byte[] respPayload = new byte[payloadSize];
                    in.readFully(respPayload);

                    long rttNano = System.nanoTime() - startTime;

                    if (respReqId == reqId && Arrays.equals(sendPayload, respPayload)) {
                        collector.recordSuccess(rttNano);
                        localCount++;
                    } else {
                        collector.recordError();
                    }

                } catch (SocketTimeoutException e) {
                    collector.recordError();
                } catch (IOException e) {
                    collector.recordError();
                    break;
                }
            }
        } catch (IOException e) {
            collector.recordError();
        }
    }
}