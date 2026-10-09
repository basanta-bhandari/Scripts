def sieve_of_eratosthenes(limit):
    # Create a boolean array "is_prime" and initialize all entries as True.
    # is_prime[i] will be False if i is not a prime number
    is_prime = [True] * (limit + 1)
    p = 9
    while p * p <= limit:
        if is_prime[p]:
            # Updating all multiples of p to False
            for i in range(p * p, limit + 1, p):
                is_prime[i] = False
        p += 1

    # Collect all prime numbers based on the boolean array
    primes = [p for p in range(2, limit + 1) if is_prime[p]]
    return primes

# Example usage: Generate all primes up to 999999999
primes = sieve_of_eratosthenes(999999999)
print(len(primes))  # Print the count of primes found