#!/usr/bin/env python3
"""
build_training_json_from_pngs.py

For each PNG in --input-dir, looks for a corresponding .art file (same basename + .art).
Reads stroke points (x,y,p) from the .art using artparser.parse_unpacked().
Applies gamma correction to the PNG and saves it as <imgName>.level.png.
Runs vtracer on the gamma-corrected PNG to produce an outline SVG (spline mode, binary).
Filters out points that are not inside any traced shape in the SVG.
Samples the SVG outline densely and computes nearest-outline distance for each remaining stroke point.
Outputs JSON: list_of_strokes -> each stroke is list of {x,y,p,radius}.
Also analyzes pressure-to-radius mapping if --analyze-pressure is specified.

Usage:
  python build_training_json_from_pngs.py --input-dir /path/to/dir --out training-points.json [--debug] [--no-flip-y] [--analyze-pressure]

  python build_training_json_from_pngs.py --input-dir eval-data --out estimated-pressure-points.json --debug

Dependencies:
  pip install numpy pillow svgpathtools scipy tqdm vtracer cairocffi scikit-learn matplotlib
"""

import os
import sys
import json
import math
import subprocess
from pathlib import Path as PathLib
from typing import List, Tuple, Optional
import numpy as np
from PIL import Image
from svgpathtools import svg2paths2, Path as SVGPath, Line, CubicBezier, QuadraticBezier, Arc
from scipy.spatial import cKDTree
from tqdm import tqdm
import argparse
import vtracer  # Import vtracer directly
import xml.etree.ElementTree as ET
from xml.dom import minidom
import cairocffi as cairo

# Try importing scikit-learn for analysis
try:
    from sklearn.cluster import KMeans
    from sklearn.metrics import r2_score
    SKLEARN_AVAILABLE = True
except ImportError:
    SKLEARN_AVAILABLE = False
    print("Warning: scikit-learn not available. Pressure-radius analysis will be limited.")

# Try importing matplotlib for plotting
try:
    import matplotlib.pyplot as plt
    MATPLOTLIB_AVAILABLE = True
except ImportError:
    MATPLOTLIB_AVAILABLE = False
    print("Warning: matplotlib not available. Plots will not be generated.")

# Try importing local artparser
try:
    sys.path.insert(1, os.path.join(sys.path[0], '../mischief-re'))
    import artparser
except Exception as e:
    artparser = None

# ----------------- Gamma Correction Function -----------------

def adjust_levels(image, black_point=0, white_point=255, gamma=1.0):
    # Convert image to numpy array
    img_array = np.array(image)
    
    # Normalize to [0, 1]
    normalized = img_array / 255.0
    
    # Apply black/white point adjustments
    adjusted = (normalized - black_point / 255.0) / ((white_point - black_point) / 255.0)
    adjusted = np.clip(adjusted, 0, 1)  # Clamp to [0, 1]
    
    # Apply gamma correction
    adjusted = np.power(adjusted, 1.0 / gamma)
    
    # Convert back to [0, 255]
    adjusted = (adjusted * 255).astype(np.uint8)
    
    return Image.fromarray(adjusted)

# ----------------- Pressure-Radius Analysis Functions -----------------

def analyze_pressure_radius_mapping(all_strokes, output_dir, debug=False):
    """
    Analyze the relationship between pressure values from artparser and computed radii.
    """
    if not all_strokes:
        print("No strokes to analyze.")
        return
    
    print("\n=== Pressure-Radius Mapping Analysis ===")
    
    # Collect all pressure and radius values
    all_pressures = []
    all_radii = []
    per_stroke_data = []  # Each element: (pressures, radii) for one stroke
    
    for stroke in all_strokes:
        pressures = []
        radii = []
        
        for pt in stroke:
            # Use pressure value
            if 'p' in pt:
                pressures.append(pt['p'])
            
            if 'radius' in pt:
                radii.append(pt['radius'])
        
        # Only include strokes with valid data
        if len(pressures) > 0 and len(radii) > 0 and len(pressures) == len(radii):
            all_pressures.extend(pressures)
            all_radii.extend(radii)
            per_stroke_data.append((pressures, radii))
    
    # Convert to numpy arrays
    all_pressures = np.array(all_pressures)
    all_radii = np.array(all_radii)
    
    # Check for valid data
    if len(all_pressures) == 0 or len(all_radii) == 0:
        print("No valid pressure-radius data to analyze.")
        return
    
    print(f"Pressure range: {min(all_pressures)} to {max(all_pressures)}")
    print(f"Radius range: {min(all_radii)} to {max(all_radii)}")
    
    # 1. Overall correlation and linear fit
    try:
        overall_corr = np.corrcoef(all_pressures, all_radii)[0, 1]
        # Linear fit: radius = a * pressure + b
        A = np.vstack([all_pressures, np.ones_like(all_pressures)]).T
        slope, intercept = np.linalg.lstsq(A, all_radii, rcond=None)[0]
        # R-squared
        predicted_radii = slope * all_pressures + intercept
        r_squared = r2_score(all_radii, predicted_radii) if SKLEARN_AVAILABLE else np.nan
    except Exception as e:
        print(f"Error in overall analysis: {e}")
        overall_corr = np.nan
        slope, intercept = np.nan, np.nan
        r_squared = np.nan
    
    print(f"Total points: {len(all_pressures)}")
    print(f"Total strokes: {len(per_stroke_data)}")
    print(f"Overall correlation: {overall_corr:.4f}")
    print(f"Overall linear fit: radius = {slope:.4f} * pressure + {intercept:.4f}")
    if SKLEARN_AVAILABLE:
        print(f"Overall R-squared: {r_squared:.4f}")
    
    # 2. Per-stroke linear fits
    slopes = []
    intercepts = []
    stroke_correlations = []
    
    for pressures, radii in per_stroke_data:
        if len(pressures) < 3:
            continue  # Skip strokes with too few points
        
        pressures = np.array(pressures)
        radii = np.array(radii)
        
        try:
            # Correlation
            corr = np.corrcoef(pressures, radii)[0, 1]
            if not np.isnan(corr):  # Only add valid correlations
                stroke_correlations.append(corr)
            
            # Linear fit
            A = np.vstack([pressures, np.ones_like(pressures)]).T
            a, b = np.linalg.lstsq(A, radii, rcond=None)[0]
            if not np.isnan(a) and not np.isnan(b):  # Only add valid slopes and intercepts
                slopes.append(a)
                intercepts.append(b)
        except Exception as e:
            continue
    
    slopes = np.array(slopes)
    intercepts = np.array(intercepts)
    stroke_correlations = np.array(stroke_correlations)
    
    print(f"\nPer-stroke analysis:")
    print(f"Valid strokes (with >=3 points): {len(slopes)}")
    if len(slopes) > 0:
        print(f"Mean correlation: {np.mean(stroke_correlations):.4f}")
        print(f"Median correlation: {np.median(stroke_correlations):.4f}")
        print(f"Std correlation: {np.std(stroke_correlations):.4f}")
        
        # Count strokes with good correlation
        good_corr = np.sum(np.abs(stroke_correlations) > 0.7)
        if len(stroke_correlations) > 0:
            print(f"Strokes with correlation > 0.7: {good_corr}/{len(stroke_correlations)} ({100*good_corr/len(stroke_correlations):.1f}%)")
    
    # 3. Cluster intercepts if scikit-learn is available
    if SKLEARN_AVAILABLE and len(intercepts) > 0:
        try:
            k = 4
            kmeans = KMeans(n_clusters=k, random_state=0).fit(intercepts.reshape(-1, 1))
            cluster_centers = kmeans.cluster_centers_.flatten()
            cluster_labels = kmeans.labels_
            
            print("\nCluster analysis (intercepts):")
            for i, center in enumerate(cluster_centers):
                mask = (cluster_labels == i)
                count = np.sum(mask)
                if count > 0:  # Only process non-empty clusters
                    mean_slope = np.mean(slopes[mask])
                    mean_corr = np.mean(stroke_correlations[mask])
                    print(f"  Cluster {i}: center={center:.3f}, count={count}, mean_slope={mean_slope:.3f}, mean_corr={mean_corr:.3f}")
            
            # Check if we have distinct cluster centers
            center_diffs = np.diff(np.sort(cluster_centers))
            min_diff = np.min(center_diffs) if len(center_diffs) > 0 else 0
            
            print(f"\nMinimum difference between cluster centers: {min_diff:.3f}")
            if min_diff > 0.5:
                print("RECOMMENDATION: The band hypothesis is confirmed.")
                print("There are distinct bands with similar slopes within each cluster.")
            else:
                print("RECOMMENDATION: The band hypothesis is not strongly supported.")
                print("The cluster centers are not well-separated.")
        except Exception as e:
            print(f"Error in cluster analysis: {e}")
    else:
        if not SKLEARN_AVAILABLE:
            print("\nSkipping cluster analysis: scikit-learn not available.")
        else:
            print("\nNo valid strokes for cluster analysis.")
    
    # 4. Generate plots if matplotlib is available and debug is enabled
    if MATPLOTLIB_AVAILABLE and debug:
        try:
            fig, axes = plt.subplots(2, 2, figsize=(12, 10))
            
            # Plot 1: Pressure vs Radius scatter
            axes[0, 0].scatter(all_pressures, all_radii, alpha=0.5, s=5)
            if len(all_pressures) > 1 and not np.isnan(slope):
                x_line = np.linspace(min(all_pressures), max(all_pressures), 100)
                y_line = slope * x_line + intercept
                axes[0, 0].plot(x_line, y_line, 'r-', label=f'Fit: r={slope:.3f}p+{intercept:.3f}')
            axes[0, 0].set_xlabel('Pressure (raw values)')
            axes[0, 0].set_ylabel('Radius')
            axes[0, 0].set_title('Pressure vs Radius')
            axes[0, 0].legend()
            
            # Plot 2: Histogram of per-stroke correlations
            if len(stroke_correlations) > 0:
                axes[0, 1].hist(stroke_correlations, bins=30, alpha=0.7)
            axes[0, 1].set_xlabel('Correlation coefficient')
            axes[0, 1].set_ylabel('Frequency')
            axes[0, 1].set_title('Per-stroke Pressure-Radius Correlation')
            
            # Plot 3: Intercept histogram with cluster centers
            if len(intercepts) > 0 and SKLEARN_AVAILABLE:
                axes[1, 0].hist(intercepts, bins=50, alpha=0.7)
                for i, center in enumerate(cluster_centers):
                    axes[1, 0].axvline(x=center, color=f'C{i}', linestyle='--', 
                                      label=f'Cluster {i}: {center:.3f}')
                axes[1, 0].set_xlabel('Intercept')
                axes[1, 0].set_ylabel('Frequency')
                axes[1, 0].set_title('Intercept Distribution with Cluster Centers')
                axes[1, 0].legend()
            
            # Plot 4: Slope vs Intercept scatter colored by cluster
            if len(intercepts) > 0 and SKLEARN_AVAILABLE and len(slopes) > 0:
                colors = [f'C{label}' for label in cluster_labels]
                axes[1, 1].scatter(slopes, intercepts, c=colors, alpha=0.7)
                axes[1, 1].set_xlabel('Slope')
                axes[1, 1].set_ylabel('Intercept')
                axes[1, 1].set_title('Slope vs Intercept by Cluster')
            
            plt.tight_layout()
            plot_path = PathLib(output_dir) / "pressure_radius_analysis_bands_estimatedpressures3.png"
            plt.savefig(plot_path, dpi=300)
            print(f"Saved analysis plot to {plot_path}")
        except Exception as e:
            print(f"Error generating plots: {e}")
    
    # 5. Save summary report
    report_path = PathLib(output_dir) / "pressure_radius_analysis.txt"
    with open(report_path, 'w') as f:
        f.write("=== Pressure-Radius Mapping Analysis ===\n")
        f.write(f"Total points: {len(all_pressures)}\n")
        f.write(f"Total strokes: {len(per_stroke_data)}\n")
        f.write(f"Overall correlation: {overall_corr:.4f}\n")
        f.write(f"Overall linear fit: radius = {slope:.4f} * pressure + {intercept:.4f}\n")
        if SKLEARN_AVAILABLE:
            f.write(f"Overall R-squared: {r_squared:.4f}\n")
        f.write("\nPer-stroke analysis:\n")
        f.write(f"Valid strokes (with >=3 points): {len(slopes)}\n")
        if len(slopes) > 0:
            f.write(f"Mean correlation: {np.mean(stroke_correlations):.4f}\n")
            f.write(f"Median correlation: {np.median(stroke_correlations):.4f}\n")
            f.write(f"Std correlation: {np.std(stroke_correlations):.4f}\n")
            good_corr = np.sum(np.abs(stroke_correlations) > 0.7)
            f.write(f"Strokes with correlation > 0.7: {good_corr}/{len(stroke_correlations)} ({100*good_corr/len(stroke_correlations):.1f}%)\n")
        if SKLEARN_AVAILABLE and len(cluster_centers) > 0:
            f.write("\nCluster analysis (intercepts):\n")
            for i, center in enumerate(cluster_centers):
                mask = (cluster_labels == i)
                count = np.sum(mask)
                if count > 0:  # Only process non-empty clusters
                    mean_slope = np.mean(slopes[mask])
                    mean_corr = np.mean(stroke_correlations[mask])
                    f.write(f"  Cluster {i}: center={center:.3f}, count={count}, mean_slope={mean_slope:.3f}, mean_corr={mean_corr:.3f}\n")
            center_diffs = np.diff(np.sort(cluster_centers))
            min_diff = np.min(center_diffs) if len(center_diffs) > 0 else 0
            f.write(f"\nMinimum difference between cluster centers: {min_diff:.3f}\n")
            if min_diff > 0.5:
                f.write("RECOMMENDATION: The band hypothesis is confirmed.\n")
                f.write("There are distinct bands with similar slopes within each cluster.\n")
            else:
                f.write("RECOMMENDATION: The band hypothesis is not strongly supported.\n")
                f.write("The cluster centers are not well-separated.\n")
    
    print(f"Saved analysis report to {report_path}")

def normalize_pressure(all_strokes, method='global'):
    """
    Normalize pressure values.
    
    Args:
        all_strokes: List of all strokes with raw pressure values
        method: 'global' or 'per-stroke' normalization method
        
    Returns:
        List of strokes with normalized pressure values
    """
    if method == 'global':
        # Collect all raw pressure values
        all_raw_pressures = []
        for stroke in all_strokes:
            for pt in stroke:
                if 'p_raw' in pt:
                    all_raw_pressures.append(pt['p_raw'])
        
        if not all_raw_pressures:
            return all_strokes
        
        # Find global min and max
        p_min = min(all_raw_pressures)
        p_max = max(all_raw_pressures)
        
        print(f"Global pressure range: {p_min} to {p_max}")
        
        # Avoid division by zero
        if p_max == p_min:
            # All pressures are the same
            for stroke in all_strokes:
                for pt in stroke:
                    if 'p_raw' in pt:
                        pt['p'] = 0.5  # Middle value
        else:
            # Normalize to [0, 1]
            for stroke in all_strokes:
                for pt in stroke:
                    if 'p_raw' in pt:
                        pt['p'] = (pt['p_raw'] - p_min) / (p_max - p_min)
    
    elif method == 'per-stroke':
        # Normalize each stroke independently
        for stroke in all_strokes:
            raw_pressures = [pt['p_raw'] for pt in stroke if 'p_raw' in pt]
            
            if not raw_pressures:
                continue
                
            p_min = min(raw_pressures)
            p_max = max(raw_pressures)
            
            # Avoid division by zero
            if p_max == p_min:
                # All pressures in this stroke are the same
                for pt in stroke:
                    if 'p_raw' in pt:
                        pt['p'] = 0.5  # Middle value
            else:
                # Normalize to [0, 1]
                for pt in stroke:
                    if 'p_raw' in pt:
                        pt['p'] = (pt['p_raw'] - p_min) / (p_max - p_min)
    
    return all_strokes

# ----------------- Cairo Path Conversion & Point Testing -----------------
# [Existing code remains unchanged]

def _quadratic_to_cubic(start, control, end):
    # Convert quadratic bezier to cubic bezier control points
    c1 = start + 2.0/3.0 * (control - start)
    c2 = end + 2.0/3.0 * (control - end)
    return c1, c2, end

def _arc_to_cairo(ctx, arc):
    # svgpathtools Arc -> cairo arc
    # arc.center, arc.radius, arc.theta, arc.delta
    cx, cy = arc.center.real, arc.center.imag
    rx, ry = arc.radius.real, arc.radius.imag
    # Only handle circular arcs (rx == ry) directly
    if abs(rx - ry) < 1e-6:
        r = rx
        start_angle = arc.theta
        end_angle = arc.theta + arc.delta
        if arc.delta >= 0:
            ctx.arc(cx, cy, r, start_angle, end_angle)
        else:
            ctx.arc_negative(cx, cy, r, start_angle, end_angle)
    else:
        # Elliptical arcs: approximate by transforming context
        ctx.save()
        ctx.translate(cx, cy)
        ctx.scale(rx, ry)
        if arc.delta >= 0:
            ctx.arc(0, 0, 1.0, arc.theta, arc.theta + arc.delta)
        else:
            ctx.arc_negative(0, 0, 1.0, arc.theta, arc.theta + arc.delta)
        ctx.restore()

def _draw_path(ctx, path, fill_rule="nonzero", transform_matrix=None):
    """Draw an SVG path in Cairo context with optional transformation"""
    ctx.new_path()
    
    # Apply transformation if provided
    if transform_matrix is not None:
        ctx.save()
        ctx.transform(cairo.Matrix(
            transform_matrix[0, 0], transform_matrix[1, 0],
            transform_matrix[0, 1], transform_matrix[1, 1],
            transform_matrix[0, 2], transform_matrix[1, 2]
        ))
    
    start = path[0].start
    ctx.move_to(start.real, start.imag)

    for seg in path:
        if isinstance(seg, Line):
            ctx.line_to(seg.end.real, seg.end.imag)
        elif isinstance(seg, CubicBezier):
            ctx.curve_to(seg.control1.real, seg.control1.imag,
                         seg.control2.real, seg.control2.imag,
                         seg.end.real, seg.end.imag)
        elif isinstance(seg, QuadraticBezier):
            c1, c2, end = _quadratic_to_cubic(seg.start, seg.control, seg.end)
            ctx.curve_to(c1.real, c1.imag, c2.real, c2.imag, end.real, end.imag)
        elif isinstance(seg, Arc):
            _arc_to_cairo(ctx, seg)
        else:
            raise NotImplementedError(f"Unsupported segment type: {type(seg)}")

    if fill_rule == "evenodd":
        ctx.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
    else:
        ctx.set_fill_rule(cairo.FILL_RULE_WINDING)
    
    # Restore transformation if applied
    if transform_matrix is not None:
        ctx.restore()

def get_svg_dimensions(svg_file):
    """Extract width, height, and viewBox from SVG file"""
    try:
        doc = minidom.parse(str(svg_file))
        svg_elements = doc.getElementsByTagName('svg')
        if not svg_elements:
            return None, None, None
            
        svg_element = svg_elements[0]
        
        # Get width and height
        width = svg_element.getAttribute('width') or None
        height = svg_element.getAttribute('height') or None
        
        # Get viewBox
        viewBox = svg_element.getAttribute('viewBox') or None
        
        # Convert width and height to numbers if possible
        try:
            width = float(width.rstrip('px')) if width else None
        except:
            width = None
            
        try:
            height = float(height.rstrip('px')) if height else None
        except:
            height = None
            
        return width, height, viewBox
    except Exception as e:
        print(f"Error parsing SVG dimensions: {e}")
        return None, None, None

def dump_svg_path_data(svg_file, num_paths=5):
    """Dump the raw path data from SVG file for debugging"""
    try:
        doc = minidom.parse(str(svg_file))
        path_elements = doc.getElementsByTagName('path')
        
        print(f"Found {len(path_elements)} path elements in SVG")
        
        for i, path_element in enumerate(path_elements[:num_paths]):
            path_data = path_element.getAttribute('d')
            print(f"Path {i} data: {path_data[:100]}{'...' if len(path_data) > 100 else ''}")
            
            # Also get transform if present
            transform = path_element.getAttribute('transform')
            if transform:
                print(f"  Transform: {transform}")
    except Exception as e:
        print(f"Error dumping SVG path data: {e}")

def parse_transform_from_string(transform_str):
    """Parse SVG transform string into a transformation matrix"""
    if not transform_str:
        return np.eye(3)
    
    # Start with identity matrix
    matrix = np.eye(3)
    
    # Parse transform commands
    import re
    transforms = re.findall(r'(\w+)\(([^)]+)\)', transform_str)
    
    for cmd, params in transforms:
        params = [float(x) for x in params.split(',')]
        
        if cmd == 'translate':
            tx, ty = params[0], params[1] if len(params) > 1 else 0
            translate_matrix = np.array([
                [1, 0, tx],
                [0, 1, ty],
                [0, 0, 1]
            ])
            matrix = matrix @ translate_matrix
            
        elif cmd == 'scale':
            sx = params[0]
            sy = params[1] if len(params) > 1 else sx
            scale_matrix = np.array([
                [sx, 0, 0],
                [0, sy, 0],
                [0, 0, 1]
            ])
            matrix = matrix @ scale_matrix
            
        elif cmd == 'rotate':
            angle = params[0]
            cx, cy = params[1], params[2] if len(params) > 2 else 0, 0
            
            # Convert to radians
            angle_rad = math.radians(angle)
            cos_a = math.cos(angle_rad)
            sin_a = math.sin(angle_rad)
            
            # Rotation matrix around origin
            rotate_matrix = np.array([
                [cos_a, -sin_a, 0],
                [sin_a, cos_a, 0],
                [0, 0, 1]
            ])
            
            # If rotation center is specified, translate to origin, rotate, translate back
            if cx != 0 or cy != 0:
                translate_to_origin = np.array([
                    [1, 0, -cx],
                    [0, 1, -cy],
                    [0, 0, 1]
                ])
                translate_back = np.array([
                    [1, 0, cx],
                    [0, 1, cy],
                    [0, 0, 1]
                ])
                rotate_matrix = translate_back @ rotate_matrix @ translate_to_origin
            
            matrix = matrix @ rotate_matrix
            
        elif cmd == 'matrix':
            if len(params) == 6:
                # SVG matrix is (a b c d e f) which corresponds to:
                # [a c e]
                # [b d f]
                # [0 0 1]
                svg_matrix = np.array([
                    [params[0], params[2], params[4]],
                    [params[1], params[3], params[5]],
                    [0, 0, 1]
                ])
                matrix = matrix @ svg_matrix
    
    return matrix

def filter_points_within_svg_paths(strokes, svg_file, image_size, flip_y=True, debug=False):
    """
    Filter out points that are not inside any filled shape in the SVG.
    
    This implementation is optimized to:
    1. Build each Cairo path once and test all points against it
    2. Properly handle coordinate system transformations
    3. Only keep points that are inside at least one shape
    
    Args:
        strokes: List of strokes, each stroke is a list of {'x','y','p'} dicts
        svg_file: Path to the SVG file
        image_size: (width, height) of the image
        flip_y: Whether to flip Y coordinate (if ART uses bottom-left origin)
        debug: Whether to print debug information
        
    Returns:
        List of strokes with only points that are inside at least one shape
    """
    # Get SVG dimensions for debugging
    svg_width, svg_height, svg_viewBox = get_svg_dimensions(svg_file)
    if debug:
        print(f"SVG dimensions: width={svg_width}, height={svg_height}, viewBox={svg_viewBox}")
        print(f"Image size: {image_size}")
        
        # Dump raw path data for debugging
        dump_svg_path_data(svg_file)
    
    # Parse SVG with minidom to get path elements and their transforms
    try:
        doc = minidom.parse(str(svg_file))
        path_elements = doc.getElementsByTagName('path')
        
        if len(path_elements) == 0:
            print("WARNING: No path elements found in SVG - all points will be kept")
            return strokes
            
        if debug:
            print(f"Found {len(path_elements)} path elements in SVG")
    except Exception as e:
        if debug:
            print(f"Error parsing SVG with minidom: {e}")
        return strokes  # Return original strokes if we can't parse SVG
    
    # Create a Cairo context
    surface = cairo.ImageSurface(cairo.FORMAT_A8, 1, 1)
    ctx = cairo.Context(surface)
    
    # Prepare all points for testing
    all_points = []
    point_to_stroke_map = []  # Maps point index back to (stroke_idx, point_idx)
    
    for stroke_idx, stroke in enumerate(strokes):
        for point_idx, pt in enumerate(stroke):
            x = float(pt['x'])
            y = float(pt['y'])
            
            # Flip Y coordinate if needed
            if flip_y:
                y = image_size[1] - y
                
            all_points.append((x, y))
            point_to_stroke_map.append((stroke_idx, point_idx))
    
    # If no points, return empty strokes
    if not all_points:
        return []
    
    # Debug: show first few points
    if debug:
        print(f"First 5 points (after Y flip): {all_points[:5]}")
    
    # Track which points are inside at least one shape
    points_inside = np.zeros(len(all_points), dtype=bool)
    
    # Process each path element with its transform
    for path_idx, path_element in enumerate(path_elements):
        # Get path data
        path_data = path_element.getAttribute('d')
        if not path_data:
            continue
            
        # Get transform attribute
        transform_str = path_element.getAttribute('transform')
        transform_matrix = parse_transform_from_string(transform_str)
        
        # Get fill rule
        fill_rule = path_element.getAttribute('fill-rule') or "nonzero"
        
        if debug and path_idx < 3:  # Debug first few paths
            print(f"\nProcessing path element {path_idx}:")
            print(f"  Fill rule: {fill_rule}")
            print(f"  Transform: {transform_str}")
            print(f"  Transform matrix: {transform_matrix}")
            print(f"  Path data: {path_data[:50]}...")
        
        # Parse path using svgpathtools
        try:
            path = SVGPath(path_data)
        except Exception as e:
            if debug:
                print(f"Failed to parse path: {e}")
            continue
        
        if debug and path_idx < 3:
            print(f"  Parsed path segments: {len(path)}")
            if path:
                print(f"  First segment start: ({path[0].start.real}, {path[0].start.imag})")
                print(f"  First segment end: ({path[0].end.real}, {path[0].end.imag})")
                print(f"  Last segment start: ({path[-1].start.real}, {path[-1].start.imag})")
                print(f"  Last segment end: ({path[-1].end.real}, {path[-1].end.imag})")
                
                # Show transformed coordinates
                first_point = np.array([path[0].start.real, path[0].start.imag, 1])
                transformed_first = transform_matrix @ first_point
                print(f"  First segment start (transformed): ({transformed_first[0]}, {transformed_first[1]})")
        
        # Build the path once with transformation
        _draw_path(ctx, path, fill_rule, transform_matrix)
        
        # Test all points against this path
        for i, (x, y) in enumerate(all_points):
            if not points_inside[i]:  # Only test if not already marked as inside
                try:
                    if ctx.in_fill(x, y):
                        points_inside[i] = True
                except Exception as e:
                    if debug:
                        print(f"Error checking point in fill: {e}")
                    continue
        
        # Clear the path for the next iteration
        ctx.new_path()
    
    # Debug: show results
    if debug:
        inside_count = np.sum(points_inside)
        print(f"\nPoints inside shapes: {inside_count}/{len(all_points)}")
        
        # Show some example points that are outside
        outside_indices = np.where(~points_inside)[0]
        if len(outside_indices) > 0:
            print(f"Example points outside shapes: {outside_indices[:5]}")
            for idx in outside_indices[:3]:
                x, y = all_points[idx]
                print(f"  Point at ({x}, {y}) is outside")
    
    # Filter strokes based on which points are inside
    filtered_strokes = []
    kept_count = 0
    
    for stroke_idx, stroke in enumerate(strokes):
        filtered_stroke = []
        for point_idx, pt in enumerate(stroke):
            # Find the corresponding index in all_points
            flat_idx = None
            for i, (s_idx, p_idx) in enumerate(point_to_stroke_map):
                if s_idx == stroke_idx and p_idx == point_idx:
                    flat_idx = i
                    break
            
            if flat_idx is not None and points_inside[flat_idx]:
                filtered_stroke.append(pt)
                kept_count += 1
        
        if filtered_stroke:  # Only keep strokes with at least one point
            filtered_strokes.append(filtered_stroke)
    
    if debug:
        total_points = sum(len(stroke) for stroke in strokes)
        print(f"Kept {kept_count}/{total_points} points inside shapes")
        
    return filtered_strokes

# ----------------- Existing Helpers -----------------

def run_cmd(cmd, debug=False):
    if debug:
        print("RUN:", " ".join(cmd))
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return p.returncode, p.stdout.decode('utf-8', errors='ignore'), p.stderr.decode('utf-8', errors='ignore')

def build_vtracer_svg(png_path: PathLib, svg_out: PathLib, debug=False):
    """
    Run vtracer with requested parameters to create an outline SVG.
    Uses colormode=binary, mode=spline, filter_speckle=2, corner_threshold=80.
    """
    try:
        vtracer.convert_image_to_svg_py(
            image_path=str(png_path),
            out_path=str(svg_out),
            colormode="binary",
            mode="spline",
            filter_speckle=1,
            corner_threshold=90,
            splice_threshold=2,
            max_iterations=10,
            color_precision=6
        )
        return svg_out.exists()
    except Exception as e:
        if debug:
            print(f"vtracer failed: {e}")
        return False

def load_points_from_art(art_path: PathLib, debug=False):
    """
    Use artparser.parse_unpacked (user-supplied) to extract stroke point lists.
    The function should return: list_of_strokes where each stroke is list of {'x','y','p'}.
    Assumes artparser has function 'parse_unpacked' that takes file path and returns an object
    with .actions (list of dicts), where stroke actions have 'action_name' == 'stroke'
    and contain 'points': [{'x':..., 'y':..., 'p':...}, ...].
    If API differs, modify this function accordingly.
    """
    if artparser is None:
        raise RuntimeError("artparser module not found; place artparser.py in the same folder or on PYTHONPATH")

    # Many artparser implementations provide a class or function; try a few sensible approaches:
    # 1) If artparser.parse_unpacked exists and accepts a path -> use it
    if hasattr(artparser, "parse_unpacked"):
        try:
            parsed = artparser.parse_unpacked(str(art_path))
            # If parse_unpacked returns a dict-like with 'actions'
            if isinstance(parsed, dict) and 'actions' in parsed:
                actions = parsed['actions']
            elif hasattr(parsed, 'actions'):
                actions = parsed.actions
            else:
                actions = parsed
        except Exception as e:
            # try to instantiate parser class
            try:
                parser = artparser.ArtParser(str(art_path))
                parser.parse_unpacked()
                actions = parser.actions
            except Exception as e2:
                raise RuntimeError(f"artparser.parse_unpacked failed: {e} / {e2}")
    else:
        # try class-based usage
        if hasattr(artparser, "ArtParser"):
            parser = artparser.ArtParser(str(art_path))
            # some versions require calling parse_unpacked explicitly
            if hasattr(parser, "parse_unpacked"):
                parser.parse_unpacked()
            actions = parser.actions
        else:
            raise RuntimeError("artparser has no parse_unpacked or ArtParser; adapt load_points_from_art() to your artparser API")

    # Walk actions and extract strokes
    strokes = []
    for act in actions:
        try:
            name = act.get('action_name') if isinstance(act, dict) else getattr(act, 'action_name', None)
        except Exception:
            name = None
        if name == 'stroke':
            # get points list
            pts = act.get('points') if isinstance(act, dict) else getattr(act, 'points', None)
            if pts and isinstance(pts, list):
                # Normalize to dicts with x,y,p floats
                stroke_pts = []
                for pt in pts:
                    # pt might be dict or object
                    if isinstance(pt, dict):
                        x = float(pt.get('x', pt.get('X', 0.0)))
                        y = float(pt.get('y', pt.get('Y', 0.0)))
                        p = float(pt.get('p', pt.get('pressure', 1.0)))
                        raw_p = int(pt.get('raw_p', pt.get('raw_p', 0)))
                    else:
                        x = float(getattr(pt, 'x', 0.0))
                        y = float(getattr(pt, 'y', 0.0))
                        p = float(getattr(pt, 'p', getattr(pt, 'pressure', 1.0)))
                        p = int(getattr(pt, 'raw_p', getattr(pt, 'raw_p', 0)))
                    stroke_pts.append({'x': x, 'y': y, 'p': p, 'raw_p': raw_p})
                if stroke_pts:
                    strokes.append(stroke_pts)
    if debug:
        print(f"Loaded {len(strokes)} strokes from {art_path}")
        # Show first few points for debugging
        if strokes and strokes[0]:
            print(f"First stroke first 5 points: {strokes[0][:5]}")
    return strokes

def parse_transform(transform_str):
    """Parse SVG transform string into a transformation matrix"""
    if not transform_str:
        return np.eye(3)
    
    # Start with identity matrix
    matrix = np.eye(3)
    
    # Parse transform commands
    import re
    transforms = re.findall(r'(\w+)\(([^)]+)\)', transform_str)
    
    for cmd, params in transforms:
        params = [float(x) for x in params.split(',')]
        
        if cmd == 'translate':
            tx, ty = params[0], params[1] if len(params) > 1 else 0
            translate_matrix = np.array([
                [1, 0, tx],
                [0, 1, ty],
                [0, 0, 1]
            ])
            matrix = matrix @ translate_matrix
            
        elif cmd == 'scale':
            sx = params[0]
            sy = params[1] if len(params) > 1 else sx
            scale_matrix = np.array([
                [sx, 0, 0],
                [0, sy, 0],
                [0, 0, 1]
            ])
            matrix = matrix @ scale_matrix
            
        elif cmd == 'rotate':
            angle = params[0]
            cx, cy = params[1], params[2] if len(params) > 2 else 0, 0
            
            # Convert to radians
            angle_rad = math.radians(angle)
            cos_a = math.cos(angle_rad)
            sin_a = math.sin(angle_rad)
            
            # Rotation matrix around origin
            rotate_matrix = np.array([
                [cos_a, -sin_a, 0],
                [sin_a, cos_a, 0],
                [0, 0, 1]
            ])
            
            # If rotation center is specified, translate to origin, rotate, translate back
            if cx != 0 or cy != 0:
                translate_to_origin = np.array([
                    [1, 0, -cx],
                    [0, 1, -cy],
                    [0, 0, 1]
                ])
                translate_back = np.array([
                    [1, 0, cx],
                    [0, 1, cy],
                    [0, 0, 1]
                ])
                rotate_matrix = translate_back @ rotate_matrix @ translate_to_origin
            
            matrix = matrix @ rotate_matrix
            
        elif cmd == 'matrix':
            if len(params) == 6:
                # SVG matrix is (a b c d e f) which corresponds to:
                # [a c e]
                # [b d f]
                # [0 0 1]
                svg_matrix = np.array([
                    [params[0], params[2], params[4]],
                    [params[1], params[3], params[5]],
                    [0, 0, 1]
                ])
                matrix = matrix @ svg_matrix
    
    return matrix

def sample_path_dense(svg_path: PathLib, image_size: Tuple[int, int], target_spacing=0.5, debug=False):
    """
    Parse SVG and return a Nx2 numpy array of sampled outline points along all paths.
    Properly handles SVG coordinate transformations including viewBox and transform attributes.
    """
    # Parse SVG with minidom to get proper structure
    try:
        doc = minidom.parse(str(svg_path))
    except Exception as e:
        if debug:
            print(f"Failed to parse SVG: {e}")
        return np.empty((0,2), dtype=float)
    
    # Get SVG root element
    svg_elements = doc.getElementsByTagName('svg')
    if not svg_elements:
        if debug:
            print("No SVG element found")
        return np.empty((0,2), dtype=float)
    
    svg_element = svg_elements[0]
    
    # Get SVG dimensions
    width = svg_element.getAttribute('width') or str(image_size[0])
    height = svg_element.getAttribute('height') or str(image_size[1])
    try:
        width = float(width.rstrip('px'))
        height = float(height.rstrip('px'))
    except:
        width, height = image_size
    
    # Get viewBox if present
    viewBox = svg_element.getAttribute('viewBox')
    if viewBox:
        try:
            parts = viewBox.split()
            if len(parts) == 4:
                min_x, min_y, view_width, view_height = map(float, parts)
            else:
                viewBox = None
        except:
            viewBox = None
    
    if not viewBox:
        min_x, min_y = 0, 0
        view_width, view_height = width, height
    
    # Calculate viewBox transformation matrix
    viewBox_matrix = np.eye(3)
    if viewBox:
        # Scale from viewBox to SVG dimensions
        scale_x = width / view_width
        scale_y = height / view_height
        
        viewBox_matrix = np.array([
            [scale_x, 0, -min_x * scale_x],
            [0, scale_y, -min_y * scale_y],
            [0, 0, 1]
        ])
    
    # Get all path elements
    path_elements = doc.getElementsByTagName('path')
    all_pts = []
    
    for path_element in path_elements:
        # Get path data
        path_data = path_element.getAttribute('d')
        if not path_data:
            continue
        
        # Get transform attribute
        transform_str = path_element.getAttribute('transform')
        transform_matrix = parse_transform(transform_str)
        
        # Parse path using svgpathtools
        try:
            path = SVGPath(path_data)
        except Exception as e:
            if debug:
                print(f"Failed to parse path: {e}")
            continue
        
        # Sample points along the path
        length = path.length(error=1e-3)
        if length <= 0:
            continue
        
        # number of samples: at least 2, spacing ~ target_spacing
        n = max(2, int(math.ceil(length / float(target_spacing))))
        
        # sample equidistant along length via parameterization
        for i in range(n + 1):
            t = i / n
            try:
                p = path.point(t)
            except Exception:
                p = path.point(t)
            
            # Get point in homogeneous coordinates
            x = p.real
            y = p.imag
            point = np.array([x, y, 1])
            
            # Apply transformations: first path transform, then viewBox transform
            transformed_point = viewBox_matrix @ transform_matrix @ point
            
            all_pts.append((transformed_point[0], transformed_point[1]))
    
    if not all_pts:
        return np.empty((0,2), dtype=float)
    
    arr = np.array(all_pts, dtype=float)
    if debug:
        print(f"Sampled {arr.shape[0]} outline points from {svg_path}")
        print(f"SVG size: {width}x{height}, ViewBox: {viewBox}")
        print(f"Image size: {image_size}")
        print(f"Sample points range: X[{arr[:,0].min():.1f}, {arr[:,0].max():.1f}], Y[{arr[:,1].min():.1f}, {arr[:,1].max():.1f}]")
    return arr

def build_kdtree_for_outline(svg_path: PathLib, image_size: Tuple[int, int], spacing=0.5, debug=False):
    pts = sample_path_dense(svg_path, image_size, target_spacing=spacing, debug=debug)
    if pts.size == 0:
        return None, None
    tree = cKDTree(pts)
    return tree, pts

def compute_radii_for_strokes(strokes: List[List[dict]], kdtree, pts_array, image_size: Tuple[int,int], flip_y=True, debug=False):
    """
    strokes: list of strokes; stroke is list of {'x','y','p'}
    kdtree: KDTree built from sampled outline points (SVG units)
    pts_array: original array of outline sample points
    image_size: (width,height) for potential bounds checking
    flip_y: whether to flip Y coordinate (if ART uses bottom-left origin)
    Returns: list of strokes with points dicts where 'radius' added
    """
    out_strokes = []
    h, w = image_size[1], image_size[0]
    
    for stroke in strokes:
        out_pts = []
        for i, pt in enumerate(stroke):
            x = float(pt['x'])
            y = float(pt['y'])
            raw_p = int(pt['raw_p'])
            p = float(pt.get('p', 1.0))
            
            # Flip Y coordinate if needed (ART might use bottom-left origin)
            if flip_y:
                y = h - y
            
            # Query KDTree for nearest outline point
            if kdtree is None:
                radius = 0.0
            else:
                dist, idx = kdtree.query([x, y], k=1)
                radius = float(dist)
            
            out_pts.append({'x': x, 'y': y, 'p': p, 'raw_p': raw_p, 'radius': radius})
        
        # Apply smoothing to fix rogue radii at the beginning of strokes
        if len(out_pts) > 3:
            # First, identify any points with unusually large radius
            # Calculate median radius for this stroke to establish baseline
            radii = [pt['radius'] for pt in out_pts]
            median_radius = np.median(radii)
            
            # Define a threshold for what's considered "rogue" (5x median or absolute 10 pixels)
            threshold = max(median_radius * 5, 10.0)
            
            # Fix rogue radii at the beginning of strokes
            for i in range(len(out_pts)):
                # Only consider the first few points of a stroke
                if i < 5 and out_pts[i]['radius'] > threshold:
                    # If we have a next point, use its radius as a reference
                    if i < len(out_pts) - 1:
                        # Blend with the next point's radius, weighted by pressure
                        next_radius = out_pts[i+1]['radius']
                        current_pressure = out_pts[i]['p']
                        
                        # Scale expected radius by pressure (lower pressure = smaller radius)
                        expected_radius = next_radius * current_pressure
                        
                        # Use the smaller of the calculated radius or expected radius
                        out_pts[i]['radius'] = min(out_pts[i]['radius'], expected_radius)
                    
                    # If this is the first point and still problematic, use a fraction of the median
                    elif i == 0 and out_pts[i]['radius'] > threshold:
                        out_pts[i]['radius'] = median_radius * 0.5
        
        out_strokes.append(out_pts)
    
    return out_strokes

def create_debug_overlay(strokes, outline_pts, image_size, output_path, stroke_index_offset=0):
    """Create an SVG overlay showing stroke points, outline, and predicted radii for debugging"""
    w, h = image_size
    with open(output_path, 'w') as f:
        f.write(f'<svg width="{w}" height="{h}" xmlns="http://www.w3.org/2000/svg">\n')

        # Outline points
        if outline_pts.shape[0] > 0:
            for x, y in outline_pts:
                f.write(f'<circle cx="{x}" cy="{y}" r="0.5" fill="blue"/>\n')

        # Stroke points
        for si, stroke in enumerate(strokes):
            global_si = stroke_index_offset + si

            if not stroke:
                continue
            for pi, pt in enumerate(stroke):
                x, y = pt['x'], pt['y']
                f.write(f'<circle cx="{x}" cy="{y}" r="3" fill="red"/>\n')

                # Predicted radius
                radius = pt.get('radius', 0)
                if radius > 0:
                    f.write(
                        f'<circle cx="{x}" cy="{y}" r="{radius}" '
                        f'fill="none" stroke="orange" opacity="50%" stroke-width="1"/>\n'
                    )

            # --- Optional: mark first/last point explicitly ---
            if len(stroke) >= 2:
                xf, yf = stroke[0]['x'], stroke[0]['y']
                xl, yl = stroke[-1]['x'], stroke[-1]['y']
                f.write(f'<circle cx="{xf}" cy="{yf}" r="4" fill="none" stroke="yellow"/>\n')
                f.write(f'<circle cx="{xl}" cy="{yl}" r="4" fill="none" stroke="purple"/>\n')

            # --- Stroke label (placed at first point) ---
            x0, y0 = stroke[0]['x'], stroke[0]['y']
            f.write(
                f'<text x="{x0 + 4}" y="{y0 - 4}" '
                f'font-size="14" font-family="Helvetica, sans-serif" font-weight="900" fill="black" stroke="white" stroke-width="4" paint-order="stroke fill">S{global_si}</text>\n'
            )

        f.write('</svg>\n')


# ----------------- Main CLI -----------------

def main():
    parser = argparse.ArgumentParser(description="Extract (x,y,p,raw_p,radius) per stroke point using artparser + vtracer + svg outlines.")
    parser.add_argument("--input-dir", "-i", required=True, help="Folder containing PNG files and matching .art files")
    parser.add_argument("--out", "-o", required=True, help="Output JSON file (list of strokes -> list of {x,y,p,radius})")
    parser.add_argument("--debug", action="store_true", help="Enable debug output and create overlay SVGs")
    parser.add_argument("--no-flip-y", action="store_true", help="Don't flip Y coordinate (default is to flip)")
    parser.add_argument("--vtracer-spacing", type=float, default=0.5, help="Outline sampling spacing in SVG units (default 0.5)")
    parser.add_argument("--no-filter", action="store_true", help="Skip filtering points outside shapes")
    parser.add_argument("--inspect-svg", action="store_true", help="Inspect SVG structure and exit")
    parser.add_argument("--gamma", type=float, default=0.9, help="Gamma correction value (default 0.9)")
    parser.add_argument("--black-point", type=int, default=0, help="Black point for gamma correction (default 0)")
    parser.add_argument("--white-point", type=int, default=255, help="White point for gamma correction (default 255)")
    parser.add_argument("--analyze-pressure", action="store_true", help="Analyze pressure-to-radius mapping")
    parser.add_argument("--normalization", type=str, default="global", choices=["global", "per-stroke"], 
                       help="Pressure normalization method (default: global)")
    args = parser.parse_args()

    indir = PathLib(args.input_dir)
    if not indir.exists():
        print("Input dir not found:", indir)
        sys.exit(1)

    pngs = sorted(indir.glob("*.png"))
    if not pngs:
        print("No PNG files found in", indir)
        sys.exit(1)

    all_out_strokes = []
    file_stroke_ranges = []  # (start_idx, end_idx, filename)

    for png in tqdm(pngs, desc="Images"):
        base = png.stem
        artfile = png.with_suffix(".art")
        if not artfile.exists():
            if args.debug:
                print("No .art for", png.name, "skipping")
            continue

        # 1) load strokes from .art using artparser.parse_unpacked()
        try:
            strokes = load_points_from_art(artfile, debug=args.debug)
        except Exception as e:
            print("Failed to parse art file", artfile, ":", e)
            continue
        if not strokes:
            if args.debug:
                print("No strokes extracted from", artfile)
            continue

        # 2) Apply gamma correction to the image and save it
        try:
            img = Image.open(png)
            adjusted_img = adjust_levels(img, 
                                        black_point=args.black_point, 
                                        white_point=args.white_point, 
                                        gamma=args.gamma)
            
            # Save the gamma-corrected image
            level_png_path = png.with_name(f"{base}.level.png")
            adjusted_img.save(level_png_path)
            
            if args.debug:
                print(f"Applied gamma correction (gamma={args.gamma}) and saved as {level_png_path}")
                
        except Exception as e:
            print(f"Failed to apply gamma correction to {png}: {e}")
            continue

        # 3) produce vtracer SVG from gamma-corrected PNG
        svg_out = png.with_suffix(".vtracer.svg")
        ok = build_vtracer_svg(level_png_path, svg_out, debug=args.debug)
        if not ok:
            print("vtracer failed for", level_png_path, " — skipping")
            continue

        # 4) Get image size
        try:
            w, h = img.size
        except Exception:
            w, h = 1920, 1080

        # 5) Inspect SVG structure if requested
        if args.inspect_svg:
            print(f"\nInspecting SVG structure for {png}:")
            svg_width, svg_height, svg_viewBox = get_svg_dimensions(svg_out)
            print(f"SVG dimensions: width={svg_width}, height={svg_height}, viewBox={svg_viewBox}")
            
            # Dump raw path data
            dump_svg_path_data(svg_out)
            
            try:
                paths, attributes, svg_attributes = svg2paths2(svg_out, return_svg_attributes=True)
                print(f"Found {len(paths)} paths in SVG")
                
                # Print some path details
                for i, (path, attr) in enumerate(zip(paths[:5], attributes[:5])):  # Show first 5 paths
                    path_type = "Unknown"
                    if path and len(path) > 0:
                        if isinstance(path[0], Line):
                            path_type = "Line"
                        elif isinstance(path[0], CubicBezier):
                            path_type = "CubicBezier"
                        elif isinstance(path[0], QuadraticBezier):
                            path_type = "QuadraticBezier"
                        elif isinstance(path[0], Arc):
                            path_type = "Arc"
                    
                    print(f"Path {i}: type={path_type}, segments={len(path)}, fill-rule={attr.get('fill-rule', 'nonzero')}")
                    
                    # Print first and last points
                    if path:
                        start = path[0].start
                        end = path[-1].end
                        print(f"  Start: ({start.real}, {start.imag}), End: ({end.real}, {end.imag})")
                
                if len(paths) > 5:
                    print(f"... and {len(paths) - 5} more paths")
            except Exception as e:
                print(f"Error inspecting SVG: {e}")
            
            # Skip processing if just inspecting
            if args.inspect_svg:
                continue

        # 6) Filter out points that are not inside any shape in the SVG (unless disabled)
        if not args.no_filter:
            filtered_strokes = filter_points_within_svg_paths(
                strokes, 
                svg_out, 
                image_size=(w, h),
                flip_y=not args.no_flip_y,  # Default is to flip Y
                debug=args.debug
            )
            
            if args.debug:
                original_count = sum(len(s) for s in strokes)
                filtered_count = sum(len(s) for s in filtered_strokes)
                print(f"Filtered strokes: {original_count} -> {filtered_count} points")
                
            strokes = filtered_strokes
            
            # If no points remain after filtering, skip this image
            if not strokes:
                if args.debug:
                    print("No points inside shapes for", png, " — skipping")
                continue

        # 7) build KD-tree of outline samples from svg
        tree, pts_array = build_kdtree_for_outline(svg_out, image_size=(w, h), 
                                                   spacing=args.vtracer_spacing, debug=args.debug)
        if tree is None:
            print("No outline points from SVG for", png, " — skipping")
            continue

        # 8) compute radii (distance to nearest outline sample) for each stroke point
        strokes_with_radius = compute_radii_for_strokes(
            strokes, tree, pts_array, 
            image_size=(w, h), 
            flip_y=not args.no_flip_y,  # Default is to flip Y
            debug=args.debug
        )

        # Create debug overlay for each image if debug is enabled
        if args.debug:
            overlay_path = png.with_suffix(".overlay.svg")
            stroke_index_offset = len(all_out_strokes)
            create_debug_overlay(
                strokes_with_radius,
                pts_array,
                (w, h),
                overlay_path,
                stroke_index_offset=stroke_index_offset
            )
            print(f"Created debug overlay: {overlay_path}")

            start_idx = len(all_out_strokes)
            end_idx = start_idx + len(strokes_with_radius) - 1

            file_stroke_ranges.append((
                start_idx,
                end_idx,
                png.with_suffix(".overlay.svg").name
            ))

        # append into global output
        all_out_strokes.extend(strokes_with_radius)

    # Save output JSON
    outp = PathLib(args.out)
    
    # Normalize pressure values
    print(f"Normalizing pressure using {args.normalization} method")
    all_out_strokes = normalize_pressure(all_out_strokes, method=args.normalization)
    
    outp.write_text(json.dumps(all_out_strokes, indent=2))
    print("Wrote", outp, "with", len(all_out_strokes), "strokes (points preserved).")

    # Write stroke index → file map
    index_map_path = outp.with_suffix(".stroke_index_map.txt")

    file_stroke_ranges.sort(key=lambda x: x[0])

    with open(index_map_path, "w") as f:
        for start, end, name in file_stroke_ranges:
            f.write(f"S{start}–S{end}: {name}\n")

    print("Wrote stroke index map to", index_map_path)

    
    # Analyze pressure-radius mapping if requested
    if args.analyze_pressure:
        # Determine output directory for analysis results
        analysis_dir = outp.parent
        analyze_pressure_radius_mapping(all_out_strokes, analysis_dir, debug=args.debug)

if __name__ == "__main__":
    main()
