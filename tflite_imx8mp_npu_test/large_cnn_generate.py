import tensorflow as tf
import numpy as np

# Representative dataset for INT8 calibration
def representative_data_gen():
    for _ in range(100):
        data = np.random.rand(1, 128, 128, 1).astype(np.float32)
        yield [data]

model = tf.keras.Sequential([
    tf.keras.layers.Input(batch_size=1, shape=(128, 128, 1)),
    tf.keras.layers.Conv2D(64, 3, padding="valid", activation="relu"),
    tf.keras.layers.MaxPool2D(pool_size=2),
    tf.keras.layers.Conv2D(128, 3, padding="valid", activation="relu"),
    tf.keras.layers.MaxPool2D(pool_size=2),
    tf.keras.layers.Conv2D(256, 3, padding="valid", activation="relu"),
    tf.keras.layers.GlobalAveragePooling2D(),
    tf.keras.layers.Dense(256, activation="relu"),
    tf.keras.layers.Dense(10, activation="softmax")
])

converter = tf.lite.TFLiteConverter.from_keras_model(model)
converter.optimizations = [tf.lite.Optimize.DEFAULT]
converter.representative_dataset = representative_data_gen
converter.target_spec.supported_ops = [tf.lite.OpsSet.TFLITE_BUILTINS_INT8]
converter.inference_input_type = tf.int8
converter.inference_output_type = tf.int8

tflite_model = converter.convert()

with open("cnn_int8.tflite", "wb") as f:
    f.write(tflite_model)
