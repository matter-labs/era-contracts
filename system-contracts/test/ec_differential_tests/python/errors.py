class CurveError(Exception):
    def __init__(self, message, error_code):
        self.message = message
        self.error_code = error_code

class NotOnCurveError(CurveError):
    def __init__(self, point):
        super().__init__(f"Point {point} is not on the curve", "NOT_ON_CURVE")

class InvalidInputError(CurveError):
    def __init__(self, message):
        super().__init__(message, "INVALID_INPUT")
