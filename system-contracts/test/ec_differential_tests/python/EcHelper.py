import sys
import json
import os
import random
from decimal import Decimal
import py_ecc
import argparse
import math

FQ, FQ2, field_modulus, is_on_curve, curve_order, b, b2, neg, multiply, G1, G2 = py_ecc.FQ, py_ecc.FQ2, py_ecc.field_modulus, py_ecc.is_on_curve, py_ecc.curve_order, py_ecc.b, py_ecc.b2, py_ecc.neg, py_ecc.multiply, py_ecc.G1, py_ecc.G2

def encode_fq(fq_elem):
    return fq_elem.n.to_bytes(32, 'big')

def encode_fq2(fq2_elem):
    # Note the reversed order of the coefficients:
    # The difference is in how the FQ2 elements are represented:

    # In the EIP, they use the mathematical notation a * i + b
    # In py_ecc, they use the programming representation [b, a]

    # This is because in the FQ2 class implementation, the first element is the constant term (b), and the second is the coefficient of i (a).

    return encode_fq(fq2_elem.coeffs[1]) + encode_fq(fq2_elem.coeffs[0])

def encode_g1_point(point):
    if point is None:
        return b'\x00' * 64  # Point at infinity

    return encode_fq(point[0]) + encode_fq(point[1])

def encode_g2_point(point):
    if point is None:
        return b'\x00' * 128  # Point at infinity

    return encode_fq2(point[0]) + encode_fq2(point[1])

def encode_result(point):
    if point is None:
        return "0x" + "0" * 128  # Return 64 bytes of zeros if the result is the point at infinity

    x, y = point

    # Convert FQ objects to integers, then to hex
    x_int = int(x.n)
    y_int = int(y.n)

    return f"0x{x_int:064x}{y_int:064x}"

# def sqrt_mod_p(x, p):
#     """Calculate the modular square root of x in field p"""
#     return pow(x, (p + 1) // 4, p)

def random_number():
    return int.from_bytes(os.urandom(32), 'big')

def generate_random_g1_point(infinity_prob, random_prob):
    # Randomly use point at infinity
    if random.random() < infinity_prob:
        return None

    # Generate truly random point
    if random.random() < random_prob:
        x = FQ(random_number())
        y = FQ(random_number())

        # Check if point is (0,0) and replace with None if so
        point = None if x == 0 and y == 0 else (x, y)

        return point

    # Calculate y-coordinate based on x-coordinate -> y has multiple solutions, thus not all resulting points are on the curve

    # Calculate y^2 (curve is y**2 = x**3 + 3)
    # y_squared = x**3 + 3

    # # Calculate y using modular square root
    # y_int = sqrt_mod_p(y_squared.n, field_modulus)
    # y = FQ(y_int)

    # Generate a random scalar within the curve order and multiply the generator point by it to get a random point that's guaranteed on the curve
    scalar = random.randint(1, curve_order - 1)
    point = multiply(G1, scalar)

    return point

def generate_random_g2_point(infinity_prob, random_prob):
    if random.random() < infinity_prob:
        return None

    # Generate a completely random point that is not necessarily on the curve
    if random.random() < random_prob:
        # Generate a completely random point (not necessarily on the curve)
        x = FQ2([random_number() for _ in range(2)])
        y = FQ2([random_number() for _ in range(2)])

        return (x, y)

    # Generate a random scalar within the curve order and multiply the generator point by it to get a random point that's guaranteed on the curve
    scalar = random.randint(1, curve_order - 1)
    point = multiply(G2, scalar)

    return point

def handle_ecadd(args):
    try:
        points = []

        points.append(generate_random_g1_point(
            infinity_prob = args.infinity_prob,
            random_prob = args.random_prob
        ))

        # Point doubling
        if random.random() < args.double_first_prob:
            # Negate the first point
            if random.random() < args.double_first_neg_prob:
                points.append(neg(points[0]))
            else:
                points.append(points[0])
        else:
            points.append(
                generate_random_g1_point(
                    infinity_prob = args.infinity_prob,
                    random_prob = args.random_prob
                )
            )

        result = "0x" + encode_g1_point(points[0]).hex() + encode_g1_point(points[1]).hex()

        print(json.dumps({"success": True, "result":result}))

    except Exception as e:
        print(json.dumps({"success": False, "error": str(e), "error_code": "UNKNOWN_ERROR"}))

def handle_ecmul(args):
    try:
        point = generate_random_g1_point(
            infinity_prob = args.infinity_prob,
            random_prob = args.random_prob
        )

        result = "0x" + encode_g1_point(point).hex()

        print(json.dumps({"success": True, "result":result}))

    except Exception as e:
        print(json.dumps({"success": False, "error": str(e), "error_code": "UNKNOWN_ERROR"}))

def handle_ecpairing(args):
    logs = []
    input_hex = "0x"

    try:
        # Generate a base G1 and G2 point
        P_g1_point = generate_random_g1_point(
            infinity_prob = args.infinity_prob,
            random_prob = args.random_prob
        )
        R_g2_point = generate_random_g2_point(
            infinity_prob = args.infinity_prob,
            random_prob = args.random_prob
        )

        logs.append("P_g1_point on curve: %s" % is_on_curve(P_g1_point, b))
        logs.append("R_g2_point on curve: %s" % is_on_curve(R_g2_point, b2))

        # Generate random scalars, ensuring their product is 1
        scalars = [random.randint(1, curve_order - 1) for _ in range(args.pairs - 1)]
        last_scalar = pow(math.prod(scalars), -1, curve_order)
        scalars.append(last_scalar)

        for k in scalars:
            Q_g1_point = None if P_g1_point is None else multiply(P_g1_point, k)
            S_g2_point = None if R_g2_point is None else multiply(R_g2_point, k)

            logs.append("Q_g1_point on curve: %s" % is_on_curve(Q_g1_point, b))
            logs.append("S_g2_point on curve: %s" % is_on_curve(S_g2_point, b2))

            input_hex += encode_g1_point(P_g1_point).hex() + encode_g2_point(R_g2_point).hex()
            input_hex += encode_g1_point(Q_g1_point).hex() + encode_g2_point(S_g2_point).hex()

        print(json.dumps({"success": True, "result":input_hex, "logs": logs}))

    except Exception as e:
        print(json.dumps({"success": False, "error": str(e), "error_code": "UNKNOWN_ERROR"}))

def main():
    parser = argparse.ArgumentParser(description="EC Point Test Helper")
    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # Add subparsers

    # EcAdd
    ecadd_parser = subparsers.add_parser("ecadd", help="Generate random input for EcAdd")
    ecadd_parser.add_argument("--infinity-prob", type=float, default=0.1,
                                     help="Probability of generating the point at infinity (default: 0.1)")
    ecadd_parser.add_argument("--random-prob", type=float, default=0.1,
                                     help="Probability of generating a completely random point (default: 0.1)")
    ecadd_parser.add_argument("--double-first-prob", type=float, default=0.1,
                                        help="Probability of doubling the first point (default: 0.1)")
    ecadd_parser.add_argument("--double-first-neg-prob", type=float, default=0.35,
                                        help="Probability of negating the first point when doubling (default: 0.35)")
    # EcMul
    ecmul_parser = subparsers.add_parser("ecmul", help="Generate random input for EcMul")
    ecmul_parser.add_argument("--infinity-prob", type=float, default=0.1,
                                     help="Probability of generating the point at infinity (default: 0.1)")
    ecmul_parser.add_argument("--random-prob", type=float, default=0.1,
                                     help="Probability of generating a completely random point (default: 0.1)")

    # EcPairing
    ecpairing_parser = subparsers.add_parser("ecpairing", help="Generate random input for EcPairing")
    ecpairing_parser.add_argument("--infinity-prob", type=float, default=0.1,
                                     help="Probability of generating the point at infinity (default: 0.1)")
    ecpairing_parser.add_argument("--random-prob", type=float, default=0.25,
                                     help="Probability of generating a completely random point (default: 0.25)")
    ecpairing_parser.add_argument("--pairs", type=int, default=1,
                                     help="Number of point pairs to generate (default: 1)")

    args = parser.parse_args()

    if args.command == "ecmul":
        handle_ecmul(args)
    elif args.command == "ecadd":
        handle_ecadd(args)
    elif args.command == "ecpairing":
        handle_ecpairing(args)
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
