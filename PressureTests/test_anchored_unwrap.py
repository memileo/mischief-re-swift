import json
import math
import matplotlib.pyplot as plt
import os
import sys

# Import the function from your artparser.py file
sys.path.insert(1, os.path.join(sys.path[0], '../mischief-re'))
from artparser import unwrap_pressure_sequence

def load_json_data(file_path):
    """Load stroke data with radius values from JSON file"""
    if not os.path.exists(file_path):
        print(f"Error: File not found at {file_path}")
        return []
    with open(file_path, 'r') as f:
        data = json.load(f)
    return data

def calculate_rmse(predicted, actual):
    """Calculate Root Mean Squared Error between two lists"""
    if len(predicted) != len(actual) or len(predicted) == 0:
        return float('inf')
    
    sum_sq_diff = 0.0
    for p, a in zip(predicted, actual):
        sum_sq_diff += (p - a) ** 2
    
    return math.sqrt(sum_sq_diff / len(predicted))

def main():
    # Load the test dataset
    input_file = 'estimated-pressure-points3.json'
    strokes_data = load_json_data(input_file)
    
    if not strokes_data:
        print("No data loaded.")
        return

    print(f"Loaded {len(strokes_data)} strokes for validation.\n")

    high_rmse_strokes = []
    all_rmse = []

    # Create a directory for plots
    if not os.path.exists('debug_plots'):
        os.makedirs('debug_plots')

    for idx, stroke in enumerate(strokes_data):
        if not stroke: 
            continue

        # 1. Extract raw_ps sequence
        # Note: We make a copy to potentially pop the terminator later
        raw_ps = [p['raw_p'] for p in stroke]
        del raw_ps[-1]
        
        # Optional: Remove trailing 0 if it exists (terminator artifact)
        # This aligns with the Swift port logic mentioned
        if len(raw_ps) > 1 and raw_ps[-1] == 0:
            raw_ps.pop()
            stroke_cleaned = stroke[:-1]
        else:
            stroke_cleaned = stroke

        if len(raw_ps) < 2:
            continue

        # 2. Run the unwrap function
        try:
            unwrapped_ps = unwrap_pressure_sequence(raw_ps)
        except Exception as e:
            print(f"Error unwrapping Stroke {idx}: {e}")
            continue

        # 3. Calculate estimates from radius
        # Formula: int(round((radius - 1) / 32 * 4095))
        estimated_ps = []
        for point in stroke_cleaned:
            r = point.get('radius', 0.0)
            # Clamp radius to ensure no negative values before calculation
            r = max(1.0, r)
            est = int(round((r - 1.0) / 32.0 * 4095.0))
            estimated_ps.append(est)

        del estimated_ps[-1]

        # 4. Calculate RMSE
        # Ensure lengths match (unwrap output length matches input length)
        min_len = min(len(unwrapped_ps), len(estimated_ps))
        if min_len == 0: continue

        rmse = calculate_rmse(unwrapped_ps[:min_len], estimated_ps[:min_len])
        all_rmse.append(rmse)

        # 5. Track high RMSE strokes
        # Using a threshold of 400 (roughly 10% of 4095 range) as "high" for printing
        if rmse > 4: # lowered to visually analyse stroke plots 
            high_rmse_strokes.append((idx, rmse))
            
            # Generate Plot for high RMSE cases
            plt.figure(figsize=(10, 4))
            plt.plot(unwrapped_ps[:min_len], label='Unwrapped (Algorithm)', linewidth=2)
            plt.plot(estimated_ps[:min_len], label='Estimated (Radius)', linestyle='--')
            
            plt.title(f'Stroke {idx} Comparison (RMSE: {(rmse / 4095):.2f})')
            plt.xlabel('Point Index')
            plt.ylabel('Pressure (0-4095)')
            plt.legend()
            plt.grid(True, alpha=0.3)
            
            plot_path = f'debug_plots/stroke_{idx}_rmse_{(rmse / 4095):.0f}.png'
            plt.savefig(plot_path)
            plt.close()

    # --- Reporting ---
    print("--- Validation Summary ---")
    if all_rmse:
        avg_rmse = sum(all_rmse) / len(all_rmse)
        print(f"Average RMSE across all strokes: {avg_rmse:.2f}")
        print(f"Min RMSE: {min(all_rmse):.2f}")
        print(f"Max RMSE: {max(all_rmse):.2f}")
    
    print("\n--- High RMSE Strokes ---")
    if high_rmse_strokes:
        # Sort by RMSE descending
        high_rmse_strokes.sort(key=lambda x: x[1], reverse=True)
        for s_idx, s_rmse in high_rmse_strokes:
            print(f"S{s_idx} (RMSE: {s_rmse:.2f})")
            
        print(f"\nPlots saved to 'debug_plots/' directory.")
    else:
        print("No strokes found with high RMSE.")

if __name__ == "__main__":
    main()
