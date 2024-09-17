// App.js

import { useEffect, useState, useRef } from 'react';
import { View, Button, Animated, StyleSheet } from 'react-native';
import TTSManager from 'react-native-sherpa-onnx-offline-tts';

const App = () => {
  const [_, setVolume] = useState(0);
  const animatedScale = useRef(new Animated.Value(1)).current;

  useEffect(() => {
    // Initialize the TTSManager with sample rate 44100 Hz and 2 channels (stereo)
    TTSManager.initialize(22050, 1);

    // Add a listener for volume updates
    const subscription = TTSManager.addVolumeListener((currentVolume: any) => {
      setVolume(currentVolume);
      // Update animation based on volume
      Animated.spring(animatedScale, {
        toValue: 1 + currentVolume * 5, // Scale factor can be adjusted
        useNativeDriver: true,
      }).start();
    });

    // Cleanup on unmount
    return () => {
      subscription.remove();
      TTSManager.deinitialize();
    };
  }, [animatedScale]);

  const handlePlay = () => {
    const text =
      'In the grand tapestry of the cosmos, the Earth spins silently amidst a sea of celestial wonders, bound by invisible forces that orchestrate the cosmic dance of planets, stars, and galaxies. Humanity, perched on this pale blue dot, has long sought to decipher the enigmatic codes of the universe, gazing upward in awe and wonder. From the ancient astronomers who meticulously charted the heavens to the modern scientists probing the fabric of space-time, the quest for understanding has been a relentless pursuit, driven by an insatiable curiosity that transcends generations.';
    const sid = 0; // Example speaker ID or similar
    const speed = 0.85; // Normal speed

    TTSManager.generateAndPlay(text, sid, speed);
  };

  const handleStop = () => {
    TTSManager.deinitialize();
  };

  return (
    <View style={styles.container}>
      <Animated.View
        style={[
          styles.circle,
          {
            transform: [{ scale: animatedScale }],
          },
        ]}
      />
      <View style={styles.buttons}>
        <Button title="Play Audio" onPress={handlePlay} />
        <Button title="Stop Audio" onPress={handleStop} />
      </View>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: '#F5FCFF',
  },
  circle: {
    width: 100,
    height: 100,
    borderRadius: 50,
    backgroundColor: 'skyblue',
    marginBottom: 50,
  },
  buttons: {
    width: '60%',
    justifyContent: 'space-between',
    height: 100,
  },
});

export default App;
