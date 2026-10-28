import numpy as np
import sounddevice as sd

# Function to generate a pure-tone sound
def generate_pure_tone(frequency, duration, volume):
    # Create a time array
    t = np.linspace(0, duration, int(duration * 44100), False)

    # Generate the pure-tone sound
    tone = volume * np.sin(2 * np.pi * frequency * t)

    return tone

# Initialize frequency and volume
initial_frequency = 125  # Starting frequency in Hz
initial_volume = 0       # Starting volume in dB

# Initialize volume step size
volume_step = 5  # dB step size

# Set the maximum volume
max_volume = 80  # dB

# Set the maximum frequency
max_frequency = 4000  # Hz

# Duration for each tone (seconds)
duration_per_tone = 0.5

while initial_frequency <= max_frequency:
    print(f"\nTesting Frequency: {initial_frequency} Hz")

    # Loop until the desired volume (e.g., 80 dB) is reached or the user quits
    while initial_volume <= max_volume:
        # Generate the pure-tone sound at the current frequency and volume
        tone = generate_pure_tone(initial_frequency, duration_per_tone, initial_volume)

        # Play the sound for this frequency and volume
        print(f"Frequency: {initial_frequency} Hz | Volume: {initial_volume} dB")
        sd.play(tone, 44100)
        sd.wait()  # Wait until the sound is finished playing

        # Ask the user if they can hear the sound
        user_response = input("Are you able to hear? (yes/no/quit): ").lower()

        # If the user quits, exit the program
        if user_response == "quit":
            exit()

        # If the user responds with "yes," record the result and break out of the loop
        if user_response == "yes":
            print(f"Result: Frequency: {initial_frequency} Hz | Volume: {initial_volume} dB")
            break

        # Increase the volume by the defined step (e.g., 5 dB)
        initial_volume += volume_step

    # Reset volume to 0 dB for the next frequency
    initial_volume = 0

    # Increase the frequency by the defined step (e.g., 100 Hz)
    initial_frequency += 100
