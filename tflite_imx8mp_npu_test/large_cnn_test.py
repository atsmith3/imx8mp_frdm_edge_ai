import numpy as np
import time
import tflite_runtime.interpreter as tflite

def benchmark(interpreter, runs=20):
    input_details = interpreter.get_input_details()
    x = np.random.randint(-128, 127, size=(1, 128, 128, 1), dtype=np.int8)
    interpreter.allocate_tensors()

    for _ in range(5):
        interpreter.set_tensor(input_details[0]['index'], x)
        interpreter.invoke()

    start = time.time()
    for _ in range(runs):
        interpreter.set_tensor(input_details[0]['index'], x)
        interpreter.invoke()
    end = time.time()

    return (end - start) / runs * 1000.0

cpu = tflite.Interpreter("cnn_int8.tflite")
cpu_ms = benchmark(cpu)
print(f"CPU: {cpu_ms:.3f} ms")

try:
    npu = tflite.Interpreter(
        "cnn_int8.tflite",
        experimental_delegates=[tflite.load_delegate("libvx_delegate.so")]
    )
    npu_ms = benchmark(npu)
    print(f"NPU: {npu_ms:.3f} ms")
except Exception as e:
    print("NPU delegate failed:", e)
