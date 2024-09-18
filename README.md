# react-native-sherpa-onnx-offline-tts

This module is wrapper over sherpa onnx for tts

## Installation

```sh
npm install react-native-sherpa-onnx-offline-tts
```

## Usage


```js
import TTSManager from 'react-native-sherpa-onnx-offline-tts';

// ...

// Initialize with a male voice model
TTSManager.initialize('male');

// Or initialize with a female voice model
TTSManager.initialize('female');

const text = "Hello, this is a test message.";
const speakerId = 0;
const speed = 1.0;

await TTSManager.generateAndPlay(text, speakerId, speed);
```


## Contributing

See the [contributing guide](CONTRIBUTING.md) to learn how to contribute to the repository and the development workflow.

## License

MIT

---

Made with [create-react-native-library](https://github.com/callstack/react-native-builder-bob)
