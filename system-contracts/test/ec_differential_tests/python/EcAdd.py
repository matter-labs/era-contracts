import sys
import json
from decimal import Decimal
import py_ecc
from errors import *

FQ, FQ2, FQ12, field_modulus = py_ecc.FQ, py_ecc.FQ2, py_ecc.FQ12, py_ecc.field_modulus

G1, G2, G12, b, b2, b12, is_inf, is_on_curve, eq, add, double, curve_order, multiply = \
      py_ecc.G1, py_ecc.G2, py_ecc.G12, py_ecc.b, py_ecc.b2, py_ecc.b12, py_ecc.is_inf, py_ecc.is_on_curve, py_ecc.eq, py_ecc.add, py_ecc.double, py_ecc.curve_order, py_ecc.multiply

def parse_coordinates(hex_input):
    # Remove '0x' prefix if present
    hex_input = hex_input.lower().replace('0x', '')

    # Ensure the input is 128 bytes (256 hex characters)
    if len(hex_input) != 256:
        raise ValueError("Input must be 128 bytes (256 hex characters) long")

    # Split the hex string into four 64-character (32-byte) parts
    parts = [hex_input[i:i+64] for i in range(0, 256, 64)]

    # Convert each part to a decimal integer
    coordinates = [int(part, 16) for part in parts]

    return coordinates

def encode_result(point):
    if point is None:
        return "0x" + "0" * 128  # Return 64 bytes of zeros if the result is the point at infinity

    x, y = point

    # Convert FQ objects to integers, then to hex
    x_int = int(x.n)
    y_int = int(y.n)

    return f"0x{x_int:064x}{y_int:064x}"

if __name__ == "__main__":
    try:
        x0, y0, x1, y1 = parse_coordinates(sys.argv[1])

        # Check if each point is (0,0) and replace with None if so
        p0 = None if x0 == 0 and y0 == 0 else (FQ(x0), FQ(y0))
        p1 = None if x1 == 0 and y1 == 0 else (FQ(x1), FQ(y1))

        # Check if points are on the curve
        if p0 is not None and not is_on_curve(p0, b):
            raise NotOnCurveError(p0)
        if p1 is not None and not is_on_curve(p1, b):
            raise NotOnCurveError(p1)

        result = add(p0, p1)

        print(json.dumps({"success": True, "result": encode_result(result)}))

    except CurveError as e:
        print(json.dumps({"success": False, "error": e.message, "error_code": e.error_code}))
    except Exception as e:
        print(json.dumps({"success": False, "error": str(e), "error_code": "UNKNOWN_ERROR"}))
