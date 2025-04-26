// App.tsx

import { useEffect, useState, useRef } from 'react';
import {
  View,
  Button,
  Animated,
  StyleSheet,
  Text,
  ActivityIndicator,
  Alert,
} from 'react-native';
import TTSManager from 'react-native-sherpa-onnx-offline-tts'; // Import your native module
import RNFS from 'react-native-fs'; // For file system operations
import { unzip } from 'react-native-zip-archive'; // For unzipping archives

const App = () => {
  // State variables
  const [volume, _setVolume] = useState(0);
  const [downloadProgress, setDownloadProgress] = useState<number>(0);
  const [isDownloading, setIsDownloading] = useState<boolean>(false);
  const [isPlaying, setIsPlaying] = useState<boolean>(false);

  // References
  const animatedScale = useRef(new Animated.Value(1)).current;
  const downloadJobIdRef = useRef<number | null>(null); // To track the download job

  useEffect(() => {
    console.log('VolumeUpdate listener registered');
    /**
     * Initializes the TTS system by downloading and setting up the model.
     */
    const initializeTTS = async () => {
      try {
        setIsDownloading(true);

        // Define the model download URL
        const modelUrl =
          'https://vocabfalconttsmodels.s3.us-east-1.amazonaws.com/vits-piper-en_US-ryan-medium.zip'; // Replace with your ZIP URL

        // Define the destination path for the archive
        const archiveFileName = 'vits-piper-en_US-ryan-medium.zip';
        const archiveFilePath = `${RNFS.DocumentDirectoryPath}/${archiveFileName}`;

        // Define the extraction path
        const extractPath = `${RNFS.DocumentDirectoryPath}/extracted`;

        // Check if the archive already exists to prevent redundant downloads
        const fileExists = await RNFS.exists(archiveFilePath);
        if (fileExists) {
          console.log('Archive already exists. Skipping download.');
          setIsDownloading(false);
          setDownloadProgress(100);

          // Extract if not already extracted
          const extractionExists = await RNFS.exists(
            `${extractPath}/vits-piper-en_US-ryan-medium/en_US-ryan-medium.onnx`
          );
          if (!extractionExists) {
            await extractArchive(archiveFilePath, extractPath);
          }

          // Initialize TTS with the extracted model
          const modelPath = `${extractPath}/vits-piper-en_US-ryan-medium/en_US-ryan-medium.onnx`;
          const tokensPath = `${extractPath}/vits-piper-en_US-ryan-medium/tokens.txt`;
          const dataDirPath = `${extractPath}/vits-piper-en_US-ryan-medium/espeak-ng-data`;

          const modelIdJson = JSON.stringify({
            modelPath,
            tokensPath,
            dataDirPath,
          });

          await TTSManager.initialize(modelIdJson);
          console.log('TTS Initialized Successfully with existing model');
          return;
        }

        // Start downloading the archive
        const downloadOptions = {
          fromUrl: modelUrl,
          toFile: archiveFilePath,
          background: true,
          discretionary: true,
          progressDivider: 1,
          begin: (_res: RNFS.DownloadBeginCallbackResult) => {
            console.log('Download started');
          },
          progress: (res: RNFS.DownloadProgressCallbackResult) => {
            const progress = res.bytesWritten / res.contentLength;
            setDownloadProgress(progress * 100);
          },
        };

        console.log('Starting download...');
        const ret = RNFS.downloadFile(downloadOptions);
        downloadJobIdRef.current = ret.jobId;

        const result = await ret.promise;

        if (result.statusCode === 200) {
          console.log('Finished downloading to ', archiveFilePath);
          setDownloadProgress(100);
        } else {
          throw new Error(
            `Failed to download archive. Status code: ${result.statusCode}`
          );
        }

        setIsDownloading(false);

        // Extract the archive
        await extractArchive(archiveFilePath, extractPath);

        // Initialize TTS with the extracted model
        const modelPath = `${extractPath}/vits-piper-en_US-ryan-medium/en_US-ryan-medium.onnx`;
        const tokensPath = `${extractPath}/vits-piper-en_US-ryan-medium/tokens.txt`;
        const dataDirPath = `${extractPath}/vits-piper-en_US-ryan-medium/espeak-ng-data`;

        const modelIdJson = JSON.stringify({
          modelPath,
          tokensPath,
          dataDirPath,
        });

        await TTSManager.initialize(modelIdJson);
        console.log('TTS Initialized Successfully with new model');
      } catch (error) {
        setIsDownloading(false);
        setDownloadProgress(0);
        console.error('Error initializing TTS:', error);
        Alert.alert(
          'Initialization Error',
          'Failed to initialize TTS. Please try again.'
        );
      }
    };
    // Initialize TTS after registering the listener
    initializeTTS();

    // Cleanup on unmount
    return () => {
      // subscription.remove();
      TTSManager.deinitialize();

      // Cancel any ongoing download if necessary
      if (downloadJobIdRef.current) {
        RNFS.stopDownload(downloadJobIdRef.current);
      }

      console.log('VolumeUpdate listener removed and TTSManager deinitialized');
    };
  }, [animatedScale]);

  /**
   * Extracts the downloaded ZIP archive.
   * @param archivePath Path to the ZIP archive.
   * @param destinationPath Path where the archive should be extracted.
   */
  const extractArchive = async (
    archivePath: string,
    destinationPath: string
  ) => {
    try {
      // Ensure the destination directory exists
      const destExists = await RNFS.exists(destinationPath);
      if (!destExists) {
        await RNFS.mkdir(destinationPath);
        console.log(`Created directory: ${destinationPath}`);
      }

      // Extract the ZIP archive
      console.log('Starting extraction...');
      await unzip(archivePath, destinationPath);
      console.log('Extraction completed.');

      // Function to recursively list files (for debugging purposes)
      const listFilesRecursively = async (
        path: string,
        prefix: string = ''
      ) => {
        const items = await RNFS.readDir(path);
        for (const item of items) {
          if (item.isDirectory()) {
            console.log(`${prefix}- Directory: ${item.name} (${item.path})`);
            await listFilesRecursively(item.path, `${prefix}  `);
          } else if (item.isFile()) {
            console.log(`${prefix}- File: ${item.name} (${item.path})`);
          }
        }
      };

      // List all extracted files recursively
      console.log('Listing extracted files:');
      await listFilesRecursively(destinationPath);
    } catch (error) {
      console.error('Error extracting archive:', error);
      throw error;
    }
  };

  /**
   * Handles the Play Audio button press.
   */
  const handlePlay = async () => {
    try {
      const text =
        'In the grand tapestry of the cosmos, the Earth spins silently amidst a sea of celestial wonders, bound by invisible forces that orchestrate the cosmic dance of planets, stars, and galaxies. Humanity, perched on this pale blue dot, has long sought to decipher the enigmatic codes of the universe, gazing upward in awe and wonder. From the ancient astronomers who meticulously charted the heavens to the modern scientists probing the fabric of space-time, the quest for understanding has been a relentless pursuit, driven by an insatiable curiosity that transcends generations.';
      const sid = 0; // Example speaker ID or similar
      const speed = 0.85; // Normal speed

      setIsPlaying(true);
      await TTSManager.generateAndPlay(text, sid, speed);
      setIsPlaying(false);
    } catch (error) {
      setIsPlaying(false);
      console.error('Error playing TTS:', error);
      Alert.alert('Playback Error', 'Failed to play TTS. Please try again.');
    }
  };

  /**
   * Handles the Stop Audio button press.
   */
  const handleStop = () => {
    TTSManager.deinitialize();
    setIsPlaying(false);
    console.log('Playback stopped.');
  };

  return (
    <View style={styles.container}>
      {/* Display Download Progress */}
      {isDownloading && (
        <View style={styles.downloadContainer}>
          <ActivityIndicator size="large" color="#0000ff" />
          <Text style={styles.downloadText}>
            Downloading Model: {downloadProgress.toFixed(2)}%
          </Text>
        </View>
      )}

      {/* Main Content */}
      {!isDownloading && (
        <>
          <Animated.View
            style={[
              styles.circle,
              {
                transform: [{ scale: animatedScale }],
              },
            ]}
          />
          <View style={styles.buttons}>
            <Button
              title="Play Audio"
              onPress={handlePlay}
              disabled={isPlaying}
            />
            <Button
              title="Stop Audio"
              onPress={handleStop}
              disabled={!isPlaying}
            />
          </View>
          <View style={styles.volumeContainer}>
            <Text>Current Volume: {volume.toFixed(2)}</Text>
          </View>
        </>
      )}
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: 'center', // Center vertically
    alignItems: 'center', // Center horizontally
    backgroundColor: '#F5FCFF',
  },
  circle: {
    width: 100,
    height: 100,
    borderRadius: 50, // Makes it a circle
    backgroundColor: 'skyblue',
    marginBottom: 50,
  },
  buttons: {
    width: '80%',
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 20,
  },
  downloadContainer: {
    alignItems: 'center',
  },
  downloadText: {
    marginTop: 10,
    fontSize: 16,
  },
  volumeContainer: {
    marginTop: 20,
  },
});

export default App;
