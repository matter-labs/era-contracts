import sys
import json
from decimal import Decimal
import py_ecc
from errors import *

FQ, FQ2, FQ12, field_modulus = py_ecc.FQ, py_ecc.FQ2, py_ecc.FQ12, py_ecc.field_modulus

G1, G2, G12, b, b2, b12, is_inf, is_on_curve, eq, add, double, curve_order, multiply = \
      py_ecc.G1, py_ecc.G2, py_ecc.G12, py_ecc.b, py_ecc.b2, py_ecc.b12, py_ecc.is_inf, py_ecc.is_on_curve, py_ecc.eq, py_ecc.add, py_ecc.double, py_ecc.curve_order, py_ecc.multiply

def parse_input(hex_input):
    # Remove '0x' prefix if present
    hex_input = hex_input.lower().replace('0x', '')

    # Ensure the input is 32 (x) + 32 (y) + 32 (scalar) = 96 bytes (192 hex characters)
    if len(hex_input) != 192:
        raise ValueError("Input must be 96 bytes (192 hex characters) long")

    x = int(hex_input[0:64], 16)
    y = int(hex_input[64:128], 16)
    scalar = int(hex_input[128:192], 16)

    return x, y, scalar

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
        x, y, scalar = parse_input(sys.argv[1])

        # Check if point is (0,0) and replace with None if so
        p = None if x == 0 and y == 0 else (FQ(x), FQ(y))

        # If point is None, return 0
        if p is None:
            print(json.dumps({"success": True, "result": encode_result(None)}))
            sys.exit(0)

        # Check if point is on the curve
        if p is not None and not is_on_curve(p, b):
            raise NotOnCurveError(p)

        result = multiply(p, scalar)

        print(json.dumps({"success": True, "result": encode_result(result)}))

    except CurveError as e:
        print(json.dumps({"success": False, "error": e.message, "error_code": e.error_code}))
    except Exception as e:
        print(json.dumps({"success": False, "error": str(e), "error_code": "UNKNOWN_ERROR"}))
